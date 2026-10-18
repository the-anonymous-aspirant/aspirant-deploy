#!/usr/bin/env bash
#
# luks_freeze_hooks.sh — the LUKS ceremony scripts open and close system_3's
# planned-maintenance freeze at the right moments (#7342, epic #7149).
#
# Root-free and side-effect-free: `s3`, cryptsetup and every disk tool the
# scripts call are stubs on PATH that only append their argv to one log, so the
# test can assert ORDER (the freeze opens before the first destructive command)
# without touching a real volume or the real freeze. Prints [PASS]/[FAIL] per
# check and exits non-zero on any failure, per the aspirant-deploy per-repo
# verify convention (tests/*.sh).
#
# Not covered here: the run-as-$SUDO_USER branch of system3_freeze.sh, which
# needs root. The ceremony's operator runbook exercises it.
#
# Run:  tests/luks_freeze_hooks.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/calls.log"
STUBS="$WORK/bin"
mkdir -p "$STUBS"
: >"$LOG"

rc=0
pass() { printf '  [PASS] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; rc=1; }

stub() {  # stub <name> [body]: log argv, then run body (default: succeed)
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s"\n%s\n' "$1" "$LOG" "${2:-exit 0}" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}
stub s3 'echo "maintenance: stub $*"'
stub cryptsetup 'case "$1" in --version) echo "cryptsetup 2.7.0";; isLuks) exit 1;; status) exit "${STUB_CRYPT_STATUS:-0}";; esac'
stub vgs 'echo "  123.00g"'
stub losetup ''
for t in umount mount mkfs.ext4 lvcreate; do stub "$t"; done
stub mountpoint 'exit 0'
stub findmnt 'echo "/dev/mapper/scratch_crypt /dev/mapper/lake_crypt /dev/mapper/data_crypt"'

run() {  # run <script> [args...] with the stubs first on PATH
  PATH="$STUBS:$PATH" S3_BIN="$STUBS/s3" "$@"
}
line_of() { grep -n -- "$1" "$LOG" | head -1 | cut -d: -f1; }

echo "=== preflight.sh ==="
: >"$LOG"
run bash "$ROOT/scripts/luks-layer1/preflight.sh" >/dev/null
if grep -q "orch maintenance" "$LOG"; then
  fail "the dry run opened a freeze (it touches nothing, so it must not)"
else
  pass "the dry run calls no freeze"
fi

: >"$LOG"
run bash "$ROOT/scripts/luks-layer1/preflight.sh" --confirm scratch >"$WORK/out" 2>&1
open_at=$(line_of "s3 orch maintenance open")
umount_at=$(line_of "umount /scratch")
if [[ -n "$open_at" && -n "$umount_at" && "$open_at" -lt "$umount_at" ]]; then
  pass "--confirm scratch opens the freeze (log line $open_at) before 'umount /scratch' (line $umount_at)"
else
  fail "--confirm scratch: open at line '${open_at:-none}', umount at line '${umount_at:-none}'"
fi
if grep -q -- "--reason LUKS ceremony: layer-1 scratch --minutes 120 --actor-id 207" "$LOG"; then
  pass "the open names the ceremony and target, 120 min, attributed to the operator (207)"
else
  fail "unexpected open argv: $(grep 'orch maintenance open' "$LOG" || echo none)"
fi
grep -q "s3 orch maintenance status" "$LOG" && pass "the freeze's status is printed after the open" \
  || fail "no status after the open"

echo "=== postcheck.sh ==="
: >"$LOG"
run bash "$ROOT/scripts/luks-layer1/postcheck.sh" >/dev/null && pc=0 || pc=$?
if [[ "$pc" -eq 0 ]] && grep -q "s3 orch maintenance close --actor-id 207" "$LOG"; then
  pass "a passing postcheck closes the freeze"
else
  fail "passing postcheck: exit $pc, close $(grep -c 'maintenance close' "$LOG" || true)x"
fi
: >"$LOG"
STUB_CRYPT_STATUS=1 run bash "$ROOT/scripts/luks-layer1/postcheck.sh" >"$WORK/out" 2>&1 && pc=0 || pc=$?
if [[ "$pc" -ne 0 ]] && ! grep -q "maintenance close" "$LOG" && grep -q "freeze stays open" "$WORK/out"; then
  pass "a failing postcheck leaves the freeze open and says so"
else
  fail "failing postcheck: exit $pc, close $(grep -c 'maintenance close' "$LOG" || true)x"
fi

echo "=== unlock.sh ==="
: >"$LOG"
(
  export PATH="$STUBS:$PATH" S3_BIN="$STUBS/s3"
  # shellcheck source=../scripts/luks-unlock/unlock.sh
  source "$ROOT/scripts/luks-unlock/unlock.sh"
  freeze_for_unlock >/dev/null
)
if grep -q -- "s3 orch maintenance open --reason LUKS post-boot unlock --minutes 60 --actor-id 207" "$LOG"; then
  pass "freeze_for_unlock opens (or extends) a 60-min freeze"
else
  fail "freeze_for_unlock: $(grep 'maintenance' "$LOG" || echo 'no call')"
fi
: >"$LOG"
run bash "$ROOT/scripts/luks-unlock/unlock.sh" --status >/dev/null 2>&1 || true
if grep -q "orch maintenance" "$LOG"; then
  fail "unlock --status touched the freeze (it is read-only)"
else
  pass "unlock --status calls no freeze"
fi
# main is root-only, so pin the call's position structurally: after the root
# check, before the first open_one.
body=$(sed -n '/^main() {/,/^}/p' "$ROOT/scripts/luks-unlock/unlock.sh")
root_at=$(grep -n 'EUID -eq 0' <<<"$body" | head -1 | cut -d: -f1)
freeze_at=$(grep -n '^  freeze_for_unlock$' <<<"$body" | head -1 | cut -d: -f1)
open_one_at=$(grep -n 'open_one ' <<<"$body" | head -1 | cut -d: -f1)
if [[ -n "$freeze_at" && "$root_at" -lt "$freeze_at" && "$freeze_at" -lt "$open_one_at" ]]; then
  pass "main calls freeze_for_unlock after the root check and before unlocking"
else
  fail "main: root check ${root_at:-?}, freeze ${freeze_at:-none}, open_one ${open_one_at:-?}"
fi

echo "=== a missing s3 never stops the ceremony ==="
: >"$LOG"
PATH="$STUBS:$PATH" S3_BIN="$WORK/no-such-s3" bash "$ROOT/scripts/luks-layer1/preflight.sh" --confirm scratch >"$WORK/out" 2>&1 && pf=0 || pf=$?
if [[ "$pf" -eq 0 ]] && grep -q "system_3 freeze skipped" "$WORK/out" && grep -q "umount /scratch" "$LOG"; then
  pass "missing s3: a [WARN], and the ceremony still ran"
else
  fail "missing s3: exit $pf; warn $(grep -c 'freeze skipped' "$WORK/out" || true)x; umount $(grep -c 'umount /scratch' "$LOG" || true)x"
fi
stub s3 'exit 1'
: >"$LOG"
run bash "$ROOT/scripts/luks-layer1/preflight.sh" --confirm scratch >"$WORK/out" 2>&1 && pf=0 || pf=$?
if [[ "$pf" -eq 0 ]] && grep -q "freeze command failed" "$WORK/out" && grep -q "umount /scratch" "$LOG"; then
  pass "a failing freeze verb: a [WARN], and the ceremony still ran"
else
  fail "failing verb: exit $pf"
fi

echo "=== summary ==="
[[ "$rc" -eq 0 ]] && echo "  all freeze-hook checks passed." || echo "  one or more checks FAILED."
exit "$rc"
