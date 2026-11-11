#!/usr/bin/env bash
#
# End-to-end KEK-guard test for `gmail_pull_and_ingest.sh --verify` (#10492,
# security c64753 on #10492).
#
# gmail_pull_and_ingest.sh reads the operator's KEK ONCE and exports it for
# BOTH children (`scripts/lake-skeleton.sh ingest`, then, with `--verify`,
# `scripts/lake-skeleton.sh verify-at-rest`) — each a separate process
# invocation. `stage_real_kek`'s `unset LAKE_KEK_HEX` only takes effect
# inside whichever child process calls it; the wrapper's own exported copy
# is untouched, so the SECOND child inherits the real key fresh, same as the
# first. Before #10492, `verify-at-rest` never called the guard at all, so
# this exact path — the one #8814's real pull is documented to use
# (`docs/GMAIL_INGEST.md:141`, `--verify`) — would persist the operator's
# real KEK to dockerd's env. This test exercises the REAL
# `scripts/lake-skeleton.sh ingest` and `scripts/lake-skeleton.sh
# verify-at-rest` (not stand-ins, unlike tests/gmail_pull_and_ingest_unit.sh,
# which deliberately stubs both to test the wrapper's own flow logic in
# isolation) with only the Gmail pull itself stubbed, to prove the full
# chain the wrapper actually drives. A fake `docker` shim intercepts every
# `compose ... run --rm duckdb ...` invocation from either child.
#
# Usage: ./tests/gmail_pull_and_ingest_kek_guard_unit.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_BIN="$TMPDIR_TEST/bin"
mkdir -p "$FAKE_BIN"
LOG="$TMPDIR_TEST/docker.log"
: > "$LOG"

cat > "$FAKE_BIN/docker" <<'SHIM'
#!/usr/bin/env bash
if [[ "$*" == *"run --rm duckdb"* ]]; then
  state="unset"
  [[ -n "${LAKE_KEK_HEX:-}" ]] && state="SET"
  echo "$state RUN: $*" >> "$DOCKER_FAKE_LOG"
fi
exit 0
SHIM
chmod +x "$FAKE_BIN/docker"

STAGING="$TMPDIR_TEST/staging"
RUN_ID="20261110T000000Z-full"
mkdir -p "$STAGING/runs/$RUN_ID"
cat > "$STAGING/runs/$RUN_ID/manifest.json" <<'EOF'
{"dataset_id": "gmail", "source": "unit test", "records": [{"path": "x", "sensitivity": "normal"}]}
EOF
echo '{"messages":[],"deleted_ids":[]}' > "$STAGING/runs/$RUN_ID/messages.json"

PULL_STUB="$TMPDIR_TEST/pull"
cat > "$PULL_STUB" <<EOF
#!/usr/bin/env bash
printf 'gmail pull: run_id=$RUN_ID mode=full exported=1 deleted=0 history=-->1\n'
exit 0
EOF
chmod +x "$PULL_STUB"

# A second run, for the negative control below — the first run's staging
# dir is deleted by a successful real ingest, so the control needs its own.
RUN_ID_2="20261110T000100Z-full"
mkdir -p "$STAGING/runs/$RUN_ID_2"
cp "$STAGING/runs/$RUN_ID/manifest.json" "$STAGING/runs/$RUN_ID_2/manifest.json"
echo '{"messages":[],"deleted_ids":[]}' > "$STAGING/runs/$RUN_ID_2/messages.json"
PULL_STUB_2="$TMPDIR_TEST/pull2"
cat > "$PULL_STUB_2" <<EOF
#!/usr/bin/env bash
printf 'gmail pull: run_id=$RUN_ID_2 mode=full exported=1 deleted=0 history=-->1\n'
exit 0
EOF
chmod +x "$PULL_STUB_2"

PASS=0
FAIL=0

: > "$LOG"
set +e
LAKE_KEK_HEX="feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface" \
  LAKE_SKELETON_ROOT="$TMPDIR_TEST/root" \
  GMAIL_STAGING_DIR="$STAGING" \
  GMAIL_PULL_CMD="$PULL_STUB" \
  LAKE_INGEST_CMD="$PWD/scripts/lake-skeleton.sh ingest" \
  LAKE_VERIFY_CMD="$PWD/scripts/lake-skeleton.sh verify-at-rest" \
  DOCKER_FAKE_LOG="$LOG" \
  PATH="$FAKE_BIN:$PATH" \
  bash scripts/gmail/gmail_pull_and_ingest.sh --verify >"$TMPDIR_TEST/out.log" 2>"$TMPDIR_TEST/err.log"
rc=$?
set -e

# Not asserting rc=0: verify-at-rest's own layer-1 check correctly reports
# NOT GREEN against this bare $TMPDIR_TEST/root (no real Garage/catalog was
# bootstrapped here — that is lake_verify_at_rest_unit.sh's job, not this
# test's). What this test asserts is that the wrapper drove ingest through
# to completion and then invoked verify-at-rest at all, which the "clear
# export removed" + both captured RUN lines below confirm independently of
# verify-at-rest's verdict.
if grep -q 'clear export removed' "$TMPDIR_TEST/out.log"; then
  PASS=$((PASS + 1)); echo "[PASS] the ingest half completed for real (clear export removed)"
else
  FAIL=$((FAIL + 1)); echo "[FAIL] the ingest half did not complete (rc=$rc)"
  cat "$TMPDIR_TEST/out.log" "$TMPDIR_TEST/err.log" >&2
fi

run_lines="$(grep ' RUN: ' "$LOG" || true)"
run_count="$(printf '%s\n' "$run_lines" | grep -c . || true)"
if [ "$run_count" -lt 2 ]; then
  FAIL=$((FAIL + 1))
  echo "[FAIL] both children (ingest, verify-at-rest) reach 'compose ... run --rm duckdb' — only $run_count did, which is not evidence either is guarded"
else
  PASS=$((PASS + 1)); echo "[PASS] both children reached 'compose ... run --rm duckdb' ($run_count calls captured)"
fi

if printf '%s\n' "$run_lines" | grep -q '^SET'; then
  FAIL=$((FAIL + 1))
  echo "[FAIL] LAKE_KEK_HEX reached docker still SET on at least one child — the operator's real KEK would persist in dockerd's env"
  printf '%s\n' "$run_lines"
else
  PASS=$((PASS + 1))
  echo "[PASS] LAKE_KEK_HEX is unset on every 'compose ... run --rm duckdb' call from both children, including the one ingest unsets only in its own process"
fi

# --- negative control: with the structural guard removed from a mutated
#     copy of lake-skeleton.sh, the verify-at-rest leg (the one this task's
#     own real gap was in) must leak. If it doesn't, this test isn't
#     testing the guard at all.

UNGUARDED="$TMPDIR_TEST/lake-skeleton-unguarded.sh"
sed '/^# Structural, not per-verb (#10492):/,/^fi$/d' ./scripts/lake-skeleton.sh > "$UNGUARDED"
if diff -q ./scripts/lake-skeleton.sh "$UNGUARDED" >/dev/null; then
  FAIL=$((FAIL + 1))
  echo "[FAIL] negative control: the guard-removal sed matched nothing — this test would pass even if the guard vanished"
else
  : > "$LOG"
  set +e
  LAKE_KEK_HEX="feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface" \
    LAKE_SKELETON_ROOT="$TMPDIR_TEST/root2" \
    GMAIL_STAGING_DIR="$STAGING" \
    GMAIL_PULL_CMD="$PULL_STUB_2" \
    LAKE_INGEST_CMD="bash $UNGUARDED ingest" \
    LAKE_VERIFY_CMD="bash $UNGUARDED verify-at-rest" \
    DOCKER_FAKE_LOG="$LOG" \
    PATH="$FAKE_BIN:$PATH" \
    bash scripts/gmail/gmail_pull_and_ingest.sh --verify >/dev/null 2>&1
  set -e
  if grep -q '^SET' "$LOG"; then
    PASS=$((PASS + 1))
    echo "[PASS] negative control: with the structural guard removed, the chain leaks LAKE_KEK_HEX to docker — this test does detect the bug it exists for"
  else
    FAIL=$((FAIL + 1))
    echo "[FAIL] negative control: no leak even with the guard removed — the sed cut must have removed the wrong thing"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
