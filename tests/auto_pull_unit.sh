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

# --- maintenance_paused ------------------------------------------------------

MARKER="$TMPDIR_TEST/.maintenance-pause"

if maintenance_paused "$MARKER"; then
  FAIL=$((FAIL + 1)); printf "  FAIL  maintenance_paused true with no marker present\n"
else
  PASS=$((PASS + 1)); printf "  PASS  maintenance_paused false when marker absent\n"
fi

touch "$MARKER"
if maintenance_paused "$MARKER"; then
  PASS=$((PASS + 1)); printf "  PASS  maintenance_paused true when marker present\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  maintenance_paused missed an existing marker\n"
fi

# An empty marker still pauses — presence is the signal, contents are advisory.
: > "$MARKER"
if maintenance_paused "$MARKER"; then
  PASS=$((PASS + 1)); printf "  PASS  maintenance_paused true for an empty marker\n"
else
  FAIL=$((FAIL + 1)); printf "  FAIL  maintenance_paused required marker contents\n"
fi
rm -f "$MARKER"

# --- checkout_provenance -----------------------------------------------------

# A non-repo directory cannot prove its compose file's provenance.
NOT_A_REPO="$TMPDIR_TEST/not-a-repo"
mkdir -p "$NOT_A_REPO"
got="$(checkout_provenance "$NOT_A_REPO")"
assert_eq "not_a_git_checkout" "$got" "checkout_provenance refuses a non-git directory"

# Build a local "origin" and a clone of it so upstream tracking is real.
ORIGIN_REPO="$TMPDIR_TEST/origin.git"
git init -q --bare --initial-branch=main "$ORIGIN_REPO"

SEED="$TMPDIR_TEST/seed"
git init -q --initial-branch=main "$SEED"
git -C "$SEED" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "seed"
git -C "$SEED" remote add origin "$ORIGIN_REPO"
git -C "$SEED" push -q origin main

CLONE="$TMPDIR_TEST/clone"
git clone -q "$ORIGIN_REPO" "$CLONE"

got="$(checkout_provenance "$CLONE")"
assert_eq "ok" "$got" "checkout_provenance passes on main tracking origin/main"

# Untracked and modified files must NOT read as drift — the cell carries stray
# .bak files, and sweeping them into the gate would wedge every deploy.
touch "$CLONE/docker-compose.yml.bak-20260710-044340"
echo "dirty" > "$CLONE/tracked-change.txt"
git -C "$CLONE" add tracked-change.txt
got="$(checkout_provenance "$CLONE")"
assert_eq "ok" "$got" "checkout_provenance ignores untracked and staged working-tree files"

# On a feature branch → drift, naming the branch.
git -C "$CLONE" checkout -q -b feature/wip
got="$(checkout_provenance "$CLONE")"
assert_eq "branch_not_main:feature/wip" "$got" "checkout_provenance refuses a feature branch"

# Detached HEAD → drift (rev-parse --abbrev-ref reports the literal "HEAD").
git -C "$CLONE" checkout -q --detach
got="$(checkout_provenance "$CLONE")"
assert_eq "branch_not_main:HEAD" "$got" "checkout_provenance refuses a detached HEAD"

# On main, but tracking nothing → drift.
git -C "$CLONE" checkout -q main
git -C "$CLONE" branch --unset-upstream
got="$(checkout_provenance "$CLONE")"
assert_eq "upstream_not_origin_main:none" "$got" "checkout_provenance refuses main with no upstream"

# On main, but tracking the wrong remote branch → drift.
git -C "$CLONE" push -q origin main:release
git -C "$CLONE" fetch -q origin
git -C "$CLONE" branch --set-upstream-to=origin/release main >/dev/null 2>&1
got="$(checkout_provenance "$CLONE")"
assert_eq "upstream_not_origin_main:origin/release" "$got" "checkout_provenance refuses main tracking a non-origin/main upstream"

echo
echo "Passed: $PASS  Failed: $FAIL"
[[ "$FAIL" -eq 0 ]]
