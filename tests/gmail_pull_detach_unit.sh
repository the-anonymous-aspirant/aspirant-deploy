#!/usr/bin/env bash
#
# `gmail_pull_and_ingest.sh --detach` under the REAL `systemd-run --user`
# (system_3 #11344, security c70261). The pull, ingest and verify are stubs
# that check they got the key on fd 3 and then sleep, so the unit can be read
# while it runs. What is checked is the result, not the code:
#
#   1. a sentinel KEK is in no /proc/<pid>/environ of any process in the
#      unit's cgroup -- and, as a positive control, the same probe FINDS it in
#      a unit that was deliberately given it in its environment;
#   2. `systemctl --user show` of the unit carries no hex;
#   3. `systemctl --user stop` mid-run leaves no key file in $XDG_RUNTIME_DIR
#      and no key in the log.
#
# Skips (exit 0, [SKIP]) where there is no user systemd to run units in.
#
# Usage: ./tests/gmail_pull_detach_unit.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
WRAPPER="$PWD/scripts/gmail/gmail_pull_and_ingest.sh"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

if ! command -v systemd-run >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "[SKIP] no user systemd here; cannot test --detach"
  exit 0
fi

fails=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

T="$(mktemp -d)"
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
units=()
cleanup() {
  for u in "${units[@]}"; do systemctl --user stop "$u" >/dev/null 2>&1 || true; done
  rm -rf "$T"
}
trap cleanup EXIT

# A 64-hex sentinel unique to this run, so a match can only be ours.
SENTINEL="$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
RUN_ID="20261116T000000Z-full"

# Stubs: each records whether its fd-3 key matched and whether LAKE_KEK_HEX
# was in its environment, then sleeps $STUB_SLEEP seconds.
cat > "$T/pull" <<'EOF'
#!/usr/bin/env bash
d="$GMAIL_STAGING_DIR"
[[ -n "${LAKE_KEK_FILE:-}" && "$(<"$LAKE_KEK_FILE")" == "$(cat "$d/.expect")" ]] && echo fd > "$d/pull.kek"
[[ -n "${LAKE_KEK_HEX:-}" ]] && echo env > "$d/pull.kekenv"
touch "$d/pull.started"
sleep "$(cat "$d/.sleep")"
mkdir -p "$d/runs/20261116T000000Z-full"
echo '{"dataset_id":"gmail","source":"stub","records":[]}' > "$d/runs/20261116T000000Z-full/manifest.json"
echo "gmail pull: run_id=20261116T000000Z-full mode=full exported=1 deleted=0 history=-->1"
EOF
cat > "$T/ingest" <<'EOF'
#!/usr/bin/env bash
d="$GMAIL_STAGING_DIR"
[[ -n "${LAKE_KEK_FILE:-}" && "$(<"$LAKE_KEK_FILE")" == "$(cat "$d/.expect")" ]] && echo fd > "$d/ingest.kek"
[[ -n "${LAKE_KEK_HEX:-}" ]] && echo env > "$d/ingest.kekenv"
echo "run stub-run: success"
EOF
chmod +x "$T/pull" "$T/ingest"

# start NAME SLEEP: launch a detached run; echoes the unit name.
start() {
  local name="$1" sleep_s="$2"
  local st="$T/$name"
  mkdir -p "$st"
  printf '%s' "$SENTINEL" > "$st/.expect"
  echo "$sleep_s" > "$st/.sleep"
  # Typed at the foreground's hidden prompt through a pty, after a pause so
  # the pty does not echo it as typeahead (an exported LAKE_KEK_HEX is refused).
  { sleep 2; printf '%s\n' "$SENTINEL"; } \
    | env GMAIL_STAGING_DIR="$st" GMAIL_PULL_CMD="$T/pull" LAKE_INGEST_CMD="$T/ingest" LAKE_VERIFY_CMD=/bin/true \
      script -qec "bash '$WRAPPER' --detach --full" /dev/null > "$st.out" 2>&1
  cp "$st.out" "$st.err"
  tr -d '\r' < "$st.out" | sed -nE 's/.*running detached as ([^;]+);.*/\1/p'
}

wait_for() { # FILE SECONDS
  for _ in $(seq 1 $(( $2 * 10 ))); do [[ -e "$1" ]] && return 0; sleep 0.1; done
  return 1
}

# pids_with_sentinel UNIT: "<pids in the unit's cgroup> <how many hold the sentinel in environ>"
pids_with_sentinel() {
  local cg n=0 total=0 pid
  cg="$(systemctl --user show -p ControlGroup --value "$1")"
  for pid in $(cat "/sys/fs/cgroup$cg/cgroup.procs" 2>/dev/null); do
    total=$((total + 1))
    if grep -qaF "$SENTINEL" "/proc/$pid/environ" 2>/dev/null; then n=$((n + 1)); fi
  done
  echo "$total $n"
}

echo "== a detached run: the key is in no environment of any process in the unit"
unit="$(start full 4)"
units+=("$unit")
[[ -n "$unit" ]] && pass "--detach starts a unit and names it ($unit)" || fail "--detach named no unit" "$(cat "$T/full.out" "$T/full.err")"
grep -q 'you can log out' "$T/full.out" && pass "the foreground says the operator can log out" || fail "no log-out line"
if grep -qF "$SENTINEL" "$T/full.out" "$T/full.err"; then fail "the foreground printed the key"; else pass "the foreground never prints the key"; fi
ls "$RUNTIME"/gmail_kek.* >/dev/null 2>&1 && fail "the hand-off file outlived the start" "$(ls "$RUNTIME"/gmail_kek.*)" \
  || pass "the hand-off file is gone by the time the foreground returns"
wait_for "$T/full/pull.started" 20 || fail "the pull stub never started"
read -r total holding <<<"$(pids_with_sentinel "$unit")"
[[ "$total" -ge 2 ]] && pass "the probe sees the unit's processes ($total)" || fail "the probe saw only $total process(es)"
[[ "$holding" -eq 0 ]] && pass "no process in the unit has the key in /proc/<pid>/environ" \
  || fail "$holding process(es) in the unit hold the key in their environment"
if systemctl --user show "$unit" | grep -qF "$SENTINEL"; then fail "systemctl --user show carries the key"; else pass "systemctl --user show carries no key"; fi

echo "== positive control: the same probe finds the key in a unit given it in its environment"
ctl="gmail-detach-control-$$"
systemd-run --user --quiet --collect --unit "$ctl" -E "CONTROL_KEY=$SENTINEL" sleep 30
units+=("$ctl")
sleep 0.5
read -r ctotal cholding <<<"$(pids_with_sentinel "$ctl")"
[[ "$cholding" -ge 1 ]] && pass "control: found in $cholding of $ctotal process(es), so a 0 above is a real 0" \
  || fail "control: the probe missed a key that was there ($ctotal process(es))"
systemctl --user stop "$ctl" >/dev/null 2>&1 || true

echo "== the run completes: both halves got the key on fd 3 and none in their environment"
for _ in $(seq 1 100); do systemctl --user is-active --quiet "$unit" || break; sleep 0.2; done
log="$(ls "$T/full"/pull-*.log 2>/dev/null | head -1)"
[[ -f "$T/full/pull.kek" && -f "$T/full/ingest.kek" ]] && pass "the pull and the ingest got the key on fd 3" || fail "a half got no key on fd 3"
[[ ! -f "$T/full/pull.kekenv" && ! -f "$T/full/ingest.kekenv" ]] && pass "neither half had LAKE_KEK_HEX in its environment" || fail "a half had LAKE_KEK_HEX"
[[ -n "$log" ]] && grep -q 'run stub-run: success' "$log" && pass "the log has the run's output" || fail "the log lacks the run's output" "$log"
[[ "$(stat -c %a "$log" 2>/dev/null)" == "600" ]] && pass "the log is 0600" || fail "log mode" "$(stat -c %a "$log" 2>/dev/null)"
if grep -qF "$SENTINEL" "$log"; then fail "the log holds the key"; else pass "the log holds no key"; fi

echo "== stopped mid-run: no key file left, no key in the log"
unit2="$(start stopped 30)"
units+=("$unit2")
wait_for "$T/stopped/pull.started" 20 || fail "the second pull stub never started"
systemctl --user stop "$unit2"
ls "$RUNTIME"/gmail_kek.* >/dev/null 2>&1 && fail "a key file is left in the runtime dir" "$(ls "$RUNTIME"/gmail_kek.*)" \
  || pass "no key file is left in \$XDG_RUNTIME_DIR after a stop"
log2="$(ls "$T/stopped"/pull-*.log 2>/dev/null | head -1)"
if [[ -n "$log2" ]] && grep -qF "$SENTINEL" "$log2"; then fail "the stopped run's log holds the key"; else pass "the stopped run's log holds no key"; fi
systemctl --user is-active --quiet "$unit2" && fail "the unit is still active after stop" || pass "the unit stopped"

echo
if [[ $fails -eq 0 ]]; then echo "gmail_pull_detach_unit: all checks passed"; else echo "gmail_pull_detach_unit: $fails check(s) FAILED"; exit 1; fi
