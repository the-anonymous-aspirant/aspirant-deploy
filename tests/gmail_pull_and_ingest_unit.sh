#!/usr/bin/env bash
#
# Test surface for scripts/gmail/gmail_pull_and_ingest.sh (system_3 #8810):
# the one-prompt wrapper around the Gmail pull (B1) and the lake ingest runner.
# Host bash, no docker, no network: the pull and the ingest are stand-ins that
# record how they were called, and the staging dir is a temp dir. Every "KEK"
# here is a synthetic string; nothing is encrypted and nothing is persisted.
#
# Usage: ./tests/gmail_pull_and_ingest_unit.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WRAPPER=scripts/gmail/gmail_pull_and_ingest.sh
fails=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/runs/20261101T120000Z-full" "$T/runs/20261101T121500Z-incremental" "$T/runs/20261101T130000Z-full"
for d in 20261101T120000Z-full 20261101T121500Z-incremental 20261101T130000Z-full; do
  echo '{"dataset_id":"gmail","source":"stub","records":[]}' > "$T/runs/$d/manifest.json"
  echo '{"messages":[],"deleted_ids":[]}' > "$T/runs/$d/messages.json"
done
echo '{"history_id":"1002"}' > "$T/state.json"
# A synthetic value that cannot be mistaken for a real KEK and that the output
# checks can grep for.
FAKE_KEK="deadbeef-synthetic-kek-0000"
# The stubs read the expected key from a file, not the environment, so that no
# process in this test holds it in its environment except by mistake.
printf '%s' "$FAKE_KEK" > "$T/.expect"
export EXPECT_FILE="$T/.expect"

# A probe every stub runs: does any ANCESTOR (the wrapper itself, its
# subshells, `script`, this test) hold the key in /proc/<pid>/environ? That is
# security's F1 (c70270 on #11428): `unset` does not clear a process's own
# start-up environment.
cat > "$T/probe-ancestors" <<'EOF'
#!/usr/bin/env bash
key="$(cat "$EXPECT_FILE")"; p=$PPID
while [[ "$p" -gt 1 ]]; do
  if grep -qaF "$key" "/proc/$p/environ" 2>/dev/null; then echo "$p" >> "$1"; fi
  p="$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 1)"
done
EOF
chmod +x "$T/probe-ancestors"

# The pull stand-in: prints the summary line STUB_SUMMARY, exits STUB_PULL_RC,
# records its argv and whether it saw the KEK.
cat > "$T/pull" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_LOG.pull.args"
if [[ -n "${LAKE_KEK_HEX:-}" ]]; then echo env > "$STUB_LOG.pull.kekenv"; fi
if [[ -n "${LAKE_KEK_FILE:-}" && "$(<"$LAKE_KEK_FILE")" == "$(cat "$EXPECT_FILE")" ]]; then echo fd > "$STUB_LOG.pull.kek"; fi
"$(dirname "$0")/probe-ancestors" "$STUB_LOG.pull.ancestorenv"
echo "pull diagnostics on stderr" >&2
printf '%s\n' "$STUB_SUMMARY"
exit "${STUB_PULL_RC:-0}"
EOF
# The ingest stand-in: records its argv and the KEK, prints a report line.
cat > "$T/ingest" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_LOG.ingest.args"
if [[ -n "${LAKE_KEK_HEX:-}" ]]; then echo env > "$STUB_LOG.ingest.kekenv"; fi
if [[ -n "${LAKE_KEK_FILE:-}" && "$(<"$LAKE_KEK_FILE")" == "$(cat "$EXPECT_FILE")" ]]; then echo fd > "$STUB_LOG.ingest.kek"; fi
"$(dirname "$0")/probe-ancestors" "$STUB_LOG.ingest.ancestorenv"
if [[ "${STUB_INGEST_RC:-0}" -ne 0 ]]; then echo "run stub-run: partial"; exit "$STUB_INGEST_RC"; fi
echo "run stub-run: success"
EOF
cat > "$T/verify" <<'EOF'
#!/usr/bin/env bash
echo verify-ran > "$STUB_LOG.verify"
if [[ -n "${LAKE_KEK_FILE:-}" && "$(<"$LAKE_KEK_FILE")" == "$(cat "$EXPECT_FILE")" ]]; then echo fd > "$STUB_LOG.verify.kek"; fi
echo "GREEN (stub)"
EOF
chmod +x "$T/pull" "$T/ingest" "$T/verify"

# run NAME [wrapper args...]; the stub env is set by the caller. Captures stdout
# and stderr separately; the wrapper's exit code lands in rc.
# The key is typed at the wrapper's real hidden prompt through a pty
# (`script`), the way the operator enters it; KEY_MODE=none runs it with no
# terminal and no key, KEY_MODE=export with the key exported (refused). Under
# the pty, stdout and stderr arrive as one stream, so .out and .err both hold it.
run() {
  local name="$1"; shift
  export STUB_LOG="$T/$name"
  rm -f "$T/$name".*
  local envs=(GMAIL_STAGING_DIR="$T" GMAIL_PULL_CMD="$T/pull" LAKE_INGEST_CMD="$T/ingest"
              LAKE_VERIFY_CMD="$T/verify" STUB_INGEST_RC="${STUB_INGEST_RC:-0}")
  set +e
  case "${KEY_MODE:-prompt}" in
    prompt)
      # Typed after a pause, as a person does: input that arrives before
      # `read -s` turns echo off would be echoed by the pty (typeahead).
      { sleep 2; printf '%s\n' "$FAKE_KEK"; } \
        | env "${envs[@]}" script -qec "bash '$WRAPPER' $*" /dev/null > "$T/$name.out" 2>&1
      rc=$?; cp "$T/$name.out" "$T/$name.err" ;;
    none)
      env "${envs[@]}" bash "$WRAPPER" "$@" > "$T/$name.out" 2> "$T/$name.err" < /dev/null; rc=$? ;;
    export)
      env "${envs[@]}" LAKE_KEK_HEX="$FAKE_KEK" bash "$WRAPPER" "$@" > "$T/$name.out" 2> "$T/$name.err" < /dev/null; rc=$? ;;
  esac
  set -e
}

echo "== the probe works: it finds the key in an ancestor that does hold it (positive control)"
rm -f "$T/control.ancestorenv"
# `; true` keeps bash from exec-ing the probe, so the keyed bash stays its parent.
env CONTROL_KEY="$FAKE_KEK" bash -c '"$0" "$1"; true' "$T/probe-ancestors" "$T/control.ancestorenv"
[[ -s "$T/control.ancestorenv" ]] && pass "control: the ancestor probe finds a key that is there" || fail "control: the probe missed a key"

echo "== the KEK is typed once at the prompt, reaches both halves, and is never printed"
STUB_SUMMARY="gmail pull: run_id=20261101T120000Z-full mode=full exported=4 deleted=0 history=-->1002" STUB_PULL_RC=0 run normal
[[ $rc -eq 0 ]] && pass "a normal run exits 0" || fail "a normal run exits 0" "rc=$rc $(cat "$T/normal.err")"
[[ -f "$T/normal.pull.kek" && -f "$T/normal.ingest.kek" ]] && pass "both the pull and the ingest got the KEK on LAKE_KEK_FILE (fd 3)" || fail "both halves got the KEK on the fd"
[[ ! -f "$T/normal.pull.kekenv" && ! -f "$T/normal.ingest.kekenv" ]] \
  && pass "neither half has LAKE_KEK_HEX in its environment (#11344, security c70261)" \
  || fail "a child inherited LAKE_KEK_HEX"
[[ ! -s "$T/normal.pull.ancestorenv" && ! -s "$T/normal.ingest.ancestorenv" ]] \
  && pass "no ancestor of either half, the wrapper included, holds the key in /proc/<pid>/environ (F1)" \
  || fail "an ancestor holds the key in its environment" "pids: $(cat "$T"/normal.*.ancestorenv 2>/dev/null)"
[[ "$(cat "$T/normal.ingest.args")" == "$T/runs/20261101T120000Z-full/manifest.json" ]] \
  && pass "the ingest got exactly <staging>/runs/<run_id>/manifest.json" \
  || fail "ingest argv" "$(cat "$T/normal.ingest.args")"
if grep -q "$FAKE_KEK" "$T/normal.out" "$T/normal.err"; then fail "the KEK never appears in the output"; else pass "the KEK never appears in the output"; fi
grep -q 'run_id=20261101T120000Z-full' "$T/normal.out" && pass "the pull's summary line is relayed" || fail "summary relayed"
grep -q 'run stub-run: success' "$T/normal.out" && pass "the ingest's report line is relayed" || fail "ingest report relayed"
[[ ! -f "$T/normal.verify" ]] && pass "verify-at-rest does not run without --verify" || fail "verify ran unasked"
[[ ! -e "$T/runs/20261101T120000Z-full" ]] && pass "after a successful real ingest the clear export (run dir) is gone" || fail "run dir kept after success"
[[ -f "$T/state.json" ]] && pass "state.json survives the deletion" || fail "state.json deleted"
grep -q 'clear export removed' "$T/normal.out" && pass "the deletion is reported" || fail "deletion not reported"

echo "== flags reach the right half"
STUB_SUMMARY="gmail pull: run_id=20261101T121500Z-incremental mode=incremental exported=1 deleted=2 history=1002->1008" run flags --full --dry-run --verify
[[ $rc -eq 0 ]] && pass "flags: exit 0" || fail "flags: exit 0" "rc=$rc $(cat "$T/flags.err")"
[[ "$(cat "$T/flags.pull.args")" == "--full" ]] && pass "--full reaches the pull" || fail "--full reaches the pull" "$(cat "$T/flags.pull.args")"
[[ "$(cat "$T/flags.ingest.args")" == "$T/runs/20261101T121500Z-incremental/manifest.json --dry-run" ]] \
  && pass "--dry-run reaches the ingest after the manifest" || fail "--dry-run placement" "$(cat "$T/flags.ingest.args")"
[[ -f "$T/flags.verify" ]] && pass "--verify runs verify-at-rest after the ingest" || fail "--verify ran"
[[ -f "$T/flags.verify.kek" ]] && pass "verify-at-rest gets the KEK on the fd too" || fail "verify got no KEK on the fd"
[[ -f "$T/runs/20261101T121500Z-incremental/messages.json" ]] && pass "--dry-run keeps the clear export for a real run" || fail "--dry-run deleted the export"
grep -q 'clear export kept at' "$T/flags.err" && pass "--dry-run says the export was kept" || fail "--dry-run kept message" "$(cat "$T/flags.err")"

echo "== a failed ingest keeps the export, says so, and exits with the ingest's code"
STUB_SUMMARY="gmail pull: run_id=20261101T130000Z-full mode=full exported=3 deleted=0 history=-->1003" STUB_INGEST_RC=1 run ingestfail
[[ $rc -eq 1 ]] && pass "ingest exit 1 propagates as 1" || fail "ingest exit propagates" "rc=$rc"
[[ -f "$T/runs/20261101T130000Z-full/messages.json" ]] && pass "failed ingest: the clear export is kept for a retry" || fail "failed ingest: export deleted"
grep -q 'clear export kept at' "$T/ingestfail.err" && pass "failed ingest: says where it is" || fail "failed ingest: kept message"
[[ -f "$T/state.json" ]] && pass "failed ingest: state.json untouched" || fail "failed ingest: state.json gone"
[[ ! -f "$T/ingestfail.verify" ]] && pass "failed ingest: no verify" || fail "failed ingest: verify ran"
unset STUB_INGEST_RC

echo "== a pull that changed nothing ingests nothing"
STUB_SUMMARY="gmail pull: run_id=20261101T130000Z-incremental mode=incremental exported=0 deleted=0 history=1008->1008 (no change; nothing to ingest)" run nochange
[[ $rc -eq 0 ]] && pass "no change: exit 0" || fail "no change: exit 0" "rc=$rc"
[[ ! -f "$T/nochange.ingest.args" ]] && pass "no change: the ingest is not called" || fail "no change: ingest was called"
grep -q 'no new run to ingest' "$T/nochange.out" && pass "no change: says so" || fail "no change: message" "$(cat "$T/nochange.out")"

echo "== a pull that failed stops the chain with its own exit code"
for code in 3 4 7; do
  STUB_SUMMARY="re-consent needed: refresh token refused" STUB_PULL_RC=$code run "pullfail$code"
  [[ $rc -eq $code ]] && pass "pull exit $code propagates as $code" || fail "pull exit $code propagates" "rc=$rc"
  [[ ! -f "$T/pullfail$code.ingest.args" ]] && pass "pull exit $code: the ingest is not called" || fail "pull exit $code: ingest called"
done

echo "== a run id whose manifest is missing is not ingested"
STUB_SUMMARY="gmail pull: run_id=20261101T140000Z-full mode=full exported=2 deleted=0 history=-->1010" run nomanifest
[[ $rc -eq 0 && ! -f "$T/nomanifest.ingest.args" ]] && pass "missing manifest: exit 0, no ingest" || fail "missing manifest" "rc=$rc"

echo "== without a terminal the wrapper refuses before pulling"
STUB_SUMMARY="gmail pull: run_id=x" KEY_MODE=none run nokek
[[ $rc -eq 2 ]] && pass "no tty: exit 2" || fail "no tty: exit 2" "rc=$rc"
[[ ! -f "$T/nokek.pull.args" ]] && pass "no tty: the pull is not called" || fail "no tty: pull was called"
grep -q 'run it from a terminal' "$T/nokek.err" && pass "no tty: says to run it from a terminal" || fail "no tty: message" "$(cat "$T/nokek.err")"

echo "== an exported LAKE_KEK_HEX is refused before anything runs (security F1, c70270 on #11428)"
STUB_SUMMARY="gmail pull: run_id=x" KEY_MODE=export run exported
[[ $rc -eq 2 ]] && pass "exported key: exit 2" || fail "exported key: exit 2" "rc=$rc"
[[ ! -f "$T/exported.pull.args" ]] && pass "exported key: the pull is not called" || fail "exported key: pull was called"
grep -q 'refusing an exported LAKE_KEK_HEX' "$T/exported.err" && pass "exported key: says why and what to do" || fail "exported key: message" "$(cat "$T/exported.err")"
if grep -qF "$FAKE_KEK" "$T/exported.out" "$T/exported.err"; then fail "exported key: the refusal prints the key"; else pass "exported key: the refusal does not print the key"; fi

echo "== an unknown argument is refused before anything runs"
STUB_SUMMARY="gmail pull: run_id=x" run badarg --oops
[[ $rc -eq 2 && ! -f "$T/badarg.pull.args" ]] && pass "unknown argument: exit 2, no pull" || fail "unknown argument" "rc=$rc"

echo
if [[ $fails -eq 0 ]]; then echo "gmail_pull_and_ingest_unit: all checks passed"; else echo "gmail_pull_and_ingest_unit: $fails check(s) FAILED"; exit 1; fi
