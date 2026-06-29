#!/usr/bin/env bash
set -euo pipefail

# Unit tests for scripts/auto-pull.sh's pure logic — decide(),
# log_decision(), and the known-bad cache helpers. No docker required.
#
# Usage: ./tests/auto_pull_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export ASPIRANT_AUTO_PULL_LOG_DIR="$TMPDIR_TEST/log"
export ASPIRANT_AUTO_PULL_STATE_DIR="$TMPDIR_TEST/state"
export ASPIRANT_AUTO_PULL_LIB=1

# Source the script in library mode (returns before main loop).
# shellcheck disable=SC1091
source ./scripts/auto-pull.sh

PASS=0
FAIL=0

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %s — expected %q got %q\n" "$label" "$expected" "$actual"
  fi
}

# decide() — same SHA on both sides → no_change
got="$(decide "sha256:aaa" "sha256:aaa" "$KNOWN_BAD_FILE")"
assert_eq "no_change" "$got" "decide returns no_change when SHAs match"

# decide() — different SHA, latest not known-bad → deploy
got="$(decide "sha256:old" "sha256:new" "$KNOWN_BAD_FILE")"
assert_eq "deploy" "$got" "decide returns deploy when SHAs differ and latest is clean"

# decide() — different SHA, latest IS known-bad → deferred_known_bad
echo "sha256:bad" > "$KNOWN_BAD_FILE"
got="$(decide "sha256:old" "sha256:bad" "$KNOWN_BAD_FILE")"
assert_eq "deferred_known_bad" "$got" "decide defers when latest is in known-bad list"

# decide() — latest empty (image never pulled) → skip_no_image
got="$(decide "sha256:old" "" "$KNOWN_BAD_FILE")"
assert_eq "skip_no_image" "$got" "decide skips when latest image SHA is empty"

# decide() — no current container (fresh boot), latest available → deploy
got="$(decide "" "sha256:new" "$KNOWN_BAD_FILE")"
assert_eq "deploy" "$got" "decide deploys when no current SHA but latest is set"

# mark_known_bad — appends new sha
: > "$KNOWN_BAD_FILE"
mark_known_bad "sha256:fail1"
got="$(cat "$KNOWN_BAD_FILE")"
assert_eq "sha256:fail1" "$got" "mark_known_bad writes new sha"

# mark_known_bad — does not duplicate
mark_known_bad "sha256:fail1"
got="$(wc -l < "$KNOWN_BAD_FILE")"
assert_eq "1" "$got" "mark_known_bad is idempotent"

# mark_known_bad — empty sha is a no-op
mark_known_bad ""
got="$(wc -l < "$KNOWN_BAD_FILE")"
assert_eq "1" "$got" "mark_known_bad ignores empty sha"

# is_known_bad — recognises a recorded sha
if is_known_bad "sha256:fail1"; then
  PASS=$((PASS + 1)); printf "  PASS  is_known_bad detects recorded sha\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  is_known_bad missed recorded sha\n"
fi

# is_known_bad — false for unrecorded sha
if is_known_bad "sha256:never"; then
  FAIL=$((FAIL + 1)); printf "  FAIL  is_known_bad false-positive on unknown sha\n"
else
  PASS=$((PASS + 1)); printf "  PASS  is_known_bad returns false for unknown sha\n"
fi

# log_decision — writes one JSON line with all fields
: > "$DECISIONS_LOG"
log_decision "server" "deploy" "sha256:old" "sha256:new" "test_reason"
got="$(wc -l < "$DECISIONS_LOG")"
assert_eq "1" "$got" "log_decision appends one line"

line="$(cat "$DECISIONS_LOG")"
for field in '"service":"server"' '"action":"deploy"' '"from_sha":"sha256:old"' '"to_sha":"sha256:new"' '"reason":"test_reason"' '"ts":'; do
  if [[ "$line" == *"$field"* ]]; then
    PASS=$((PASS + 1)); printf "  PASS  log line contains %s\n" "$field"
  else
    FAIL=$((FAIL + 1)); printf "  FAIL  log line missing %s — got %s\n" "$field" "$line"
  fi
done

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
