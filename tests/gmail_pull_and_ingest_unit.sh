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
mkdir -p "$T/runs/20261101T120000Z-full" "$T/runs/20261101T121500Z-incremental"
echo '{"dataset_id":"gmail","source":"stub","records":[]}' > "$T/runs/20261101T120000Z-full/manifest.json"
echo '{"dataset_id":"gmail","source":"stub","records":[]}' > "$T/runs/20261101T121500Z-incremental/manifest.json"
# A synthetic value that cannot be mistaken for a real KEK and that the output
# checks can grep for.
FAKE_KEK="deadbeef-synthetic-kek-0000"

# The pull stand-in: prints the summary line STUB_SUMMARY, exits STUB_PULL_RC,
# records its argv and whether it saw the KEK.
cat > "$T/pull" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_LOG.pull.args"
if [[ -n "${LAKE_KEK_HEX:-}" ]]; then echo kek-seen > "$STUB_LOG.pull.kek"; fi
echo "pull diagnostics on stderr" >&2
printf '%s\n' "$STUB_SUMMARY"
exit "${STUB_PULL_RC:-0}"
EOF
# The ingest stand-in: records its argv and the KEK, prints a report line.
cat > "$T/ingest" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_LOG.ingest.args"
if [[ -n "${LAKE_KEK_HEX:-}" ]]; then echo kek-seen > "$STUB_LOG.ingest.kek"; fi
echo "run stub-run: success"
EOF
cat > "$T/verify" <<'EOF'
#!/usr/bin/env bash
echo verify-ran > "$STUB_LOG.verify"
echo "GREEN (stub)"
EOF
chmod +x "$T/pull" "$T/ingest" "$T/verify"

# run NAME [wrapper args...]; the stub env is set by the caller. Captures stdout
# and stderr separately; the wrapper's exit code lands in rc.
run() {
  local name="$1"; shift
  export STUB_LOG="$T/$name"
  rm -f "$T/$name".*
  set +e
  GMAIL_STAGING_DIR="$T" GMAIL_PULL_CMD="$T/pull" LAKE_INGEST_CMD="$T/ingest" LAKE_VERIFY_CMD="$T/verify" \
    bash "$WRAPPER" "$@" > "$T/$name.out" 2> "$T/$name.err" < /dev/null
  rc=$?
  set -e
}

echo "== the KEK is read once and reaches both halves, and is never printed"
export LAKE_KEK_HEX="$FAKE_KEK"
STUB_SUMMARY="gmail pull: run_id=20261101T120000Z-full mode=full exported=4 deleted=0 history=-->1002" STUB_PULL_RC=0 run normal
[[ $rc -eq 0 ]] && pass "a normal run exits 0" || fail "a normal run exits 0" "rc=$rc $(cat "$T/normal.err")"
[[ -f "$T/normal.pull.kek" && -f "$T/normal.ingest.kek" ]] && pass "both the pull and the ingest saw LAKE_KEK_HEX" || fail "both halves saw the KEK"
[[ "$(cat "$T/normal.ingest.args")" == "$T/runs/20261101T120000Z-full/manifest.json" ]] \
  && pass "the ingest got exactly <staging>/runs/<run_id>/manifest.json" \
  || fail "ingest argv" "$(cat "$T/normal.ingest.args")"
if grep -q "$FAKE_KEK" "$T/normal.out" "$T/normal.err"; then fail "the KEK never appears in the output"; else pass "the KEK never appears in the output"; fi
grep -q 'run_id=20261101T120000Z-full' "$T/normal.out" && pass "the pull's summary line is relayed" || fail "summary relayed"
grep -q 'run stub-run: success' "$T/normal.out" && pass "the ingest's report line is relayed" || fail "ingest report relayed"
[[ ! -f "$T/normal.verify" ]] && pass "verify-at-rest does not run without --verify" || fail "verify ran unasked"

echo "== flags reach the right half"
STUB_SUMMARY="gmail pull: run_id=20261101T121500Z-incremental mode=incremental exported=1 deleted=2 history=1002->1008" run flags --full --dry-run --verify
[[ $rc -eq 0 ]] && pass "flags: exit 0" || fail "flags: exit 0" "rc=$rc $(cat "$T/flags.err")"
[[ "$(cat "$T/flags.pull.args")" == "--full" ]] && pass "--full reaches the pull" || fail "--full reaches the pull" "$(cat "$T/flags.pull.args")"
[[ "$(cat "$T/flags.ingest.args")" == "$T/runs/20261101T121500Z-incremental/manifest.json --dry-run" ]] \
  && pass "--dry-run reaches the ingest after the manifest" || fail "--dry-run placement" "$(cat "$T/flags.ingest.args")"
[[ -f "$T/flags.verify" ]] && pass "--verify runs verify-at-rest after the ingest" || fail "--verify ran"

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

echo "== without a KEK and without a terminal the wrapper refuses before pulling"
unset LAKE_KEK_HEX
STUB_SUMMARY="gmail pull: run_id=x" run nokek
[[ $rc -eq 2 ]] && pass "no KEK, no tty: exit 2" || fail "no KEK, no tty: exit 2" "rc=$rc"
[[ ! -f "$T/nokek.pull.args" ]] && pass "no KEK: the pull is not called" || fail "no KEK: pull was called"
grep -q 'LAKE_KEK_HEX is not set' "$T/nokek.err" && pass "no KEK: says how to set it" || fail "no KEK: message" "$(cat "$T/nokek.err")"

echo "== an unknown argument is refused before anything runs"
export LAKE_KEK_HEX="$FAKE_KEK"
STUB_SUMMARY="gmail pull: run_id=x" run badarg --oops
[[ $rc -eq 2 && ! -f "$T/badarg.pull.args" ]] && pass "unknown argument: exit 2, no pull" || fail "unknown argument" "rc=$rc"

echo
if [[ $fails -eq 0 ]]; then echo "gmail_pull_and_ingest_unit: all checks passed"; else echo "gmail_pull_and_ingest_unit: $fails check(s) FAILED"; exit 1; fi
