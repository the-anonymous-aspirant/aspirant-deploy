#!/usr/bin/env bash
#
# Unit surface for scripts/publish-lake-client.sh — the republish LANE.
# Task #4441, sibling of tests/lake_client_image_unit.sh (#4290).
#
# #4290 gave the lake client image a check; this covers the thing that clears
# it. Host-only on purpose: no docker, no network, no credential. Every
# assertion here is about the two properties that make the script worth having
# rather than about docker's behaviour:
#
#   1. it will not publish without an explicit flag AND a real credential, and
#      a refusal leaves the compose file byte-identical;
#   2. the repin is welded to the push — the digest surgery is exact, touches
#      no other pinned image in the file, and is idempotent.
#
# The publish leg itself is never exercised: it is outward-facing, this box has
# no write:packages scope, and a test that pushed would be the bug.
#
# Usage: ./tests/lake_client_publish_unit.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

SCRIPT=scripts/publish-lake-client.sh
DOCKERFILE=Dockerfile-LakeDuckDB
COMPOSE=docker-compose.lake-skeleton.yml
fails=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- the script itself ------------------------------------------------------

echo "the script:"

if [ -x "$SCRIPT" ]; then
  pass "${SCRIPT} exists and is executable"
else
  fail "${SCRIPT} is missing or not executable" "nothing below can be checked"
  echo
  echo "[FAIL] lake client publish: $fails check(s) failed"
  exit 1
fi

if bash -n "$SCRIPT" 2>/dev/null; then
  pass "parses clean"
else
  fail "bash -n reports a syntax error"
fi

# Pull in the REAL derive_tag / repin_compose / has_write_credential rather
# than keeping a copy here. A copied helper passes its own tests forever while
# the script it was copied from drifts -- and drift between a check and the
# thing it checks is the exact failure (#4134/#4290) this lane exists to close.
# shellcheck disable=SC1090
LAKE_PUBLISH_SOURCE_ONLY=1 . "$SCRIPT"

if declare -f derive_tag >/dev/null && declare -f repin_compose >/dev/null; then
  pass "sources its helpers from ${SCRIPT} (no copy in this file)"
else
  fail "could not source the script's helpers" "the assertions below would test a copy"
  echo
  echo "[FAIL] lake client publish: $fails check(s) failed"
  exit 1
fi

# --- tag derivation ---------------------------------------------------------
#
# The tag tracks the DuckDB version (docs/LAKE_SKELETON.md), and the script
# derives it rather than taking it as an argument. These assert it reads the
# same version the check reads, and that it REFUSES rather than guessing when
# the Dockerfile is ambiguous.

echo
echo "tag derivation:"

# Positive control first: the helper must find the version that is really in
# the Dockerfile, or the two negative cases below prove nothing (an always-
# failing parser would "pass" them).
REAL_VERSION="$(grep -oE 'duckdb==[0-9][0-9A-Za-z.]*' "$DOCKERFILE" | head -1 | cut -d= -f3 || true)"
if [ -n "$REAL_VERSION" ] && [ "$(derive_tag "$DOCKERFILE")" = "$REAL_VERSION" ]; then
  pass "derives :${REAL_VERSION} from ${DOCKERFILE}"
else
  fail "does not derive the Dockerfile's duckdb version" \
       "read '$(derive_tag "$DOCKERFILE" || true)', file has '${REAL_VERSION}'"
fi

printf 'FROM python:3.12-slim\nRUN pip install pytz==2025.2\n' > "$TMP/Dockerfile.none"
if derive_tag "$TMP/Dockerfile.none" >/dev/null 2>&1; then
  fail "accepts a Dockerfile with no duckdb== pin" "it would tag the image from nothing"
else
  pass "refuses a Dockerfile with no duckdb== pin"
fi

printf 'RUN pip install duckdb==1.5.4\nRUN pip install duckdb==1.6.0\n' > "$TMP/Dockerfile.two"
if derive_tag "$TMP/Dockerfile.two" >/dev/null 2>&1; then
  fail "accepts a Dockerfile with two duckdb== pins" "one tag would name two images"
else
  pass "refuses a Dockerfile with two duckdb== pins"
fi

# --- the publish gate -------------------------------------------------------
#
# The assertion that matters most: an unauthorised publish must not be one
# flag away. With the credential forced absent, --push must fail, say what is
# missing, and leave the compose file untouched.

echo
echo "the publish gate:"

# A poisoned `docker` first on PATH turns "the script did not call docker" from
# an unobservable claim into a loud failure. Without it, a refusal that DID
# shell out would look identical to one that did not.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'POISON'
#!/usr/bin/env bash
echo "POISONED-DOCKER-WAS-CALLED: $*" >&2
exit 97
POISON
chmod +x "$TMP/bin/docker"

# Positive control for the poison itself: if `docker` on this PATH did NOT
# announce itself, every "no docker call" pass below would be vacuous.
# Capture, then match. Under `set -o pipefail` a pipeline reports the poison's
# own exit code (97), not grep's, so `docker ... | grep -q` would read as a
# failed control even when the poison fired.
set +e
CONTROL="$(PATH="$TMP/bin:$PATH" docker version 2>&1)"
set -e
case "$CONTROL" in
  *POISONED-DOCKER-WAS-CALLED*) pass "the poisoned docker on PATH announces itself (control)" ;;
  *) fail "the poisoned docker is not on PATH" "the no-docker-call assertions below prove nothing" ;;
esac

# A REAL --push with no credential: it must refuse before it builds, so
# nothing is spent and nothing is written.
BEFORE="$(sha256sum "$COMPOSE" | cut -d' ' -f1)"
set +e
OUT="$(PATH="$TMP/bin:$PATH" LAKE_PUBLISH_FORCE_NO_CREDENTIAL=1 "$SCRIPT" --push 2>&1)"
RC=$?
set -e
AFTER="$(sha256sum "$COMPOSE" | cut -d' ' -f1)"

if [ "$RC" -ne 0 ]; then
  pass "--push exits non-zero without a write credential (rc=${RC})"
else
  fail "--push succeeded with no write credential" "the gate is not a gate"
fi

case "$OUT" in
  *write:packages*) pass "the refusal names the missing scope" ;;
  *) fail "the refusal does not name write:packages" "the operator cannot tell what to provision" ;;
esac

case "$OUT" in
  *POISONED-DOCKER-WAS-CALLED*)
    fail "the refused --push still ran docker" "it must refuse BEFORE spending a build" ;;
  *) pass "the refused --push never reaches docker" ;;
esac

if [ "$BEFORE" = "$AFTER" ]; then
  pass "${COMPOSE} is byte-identical after a refused publish"
else
  fail "${COMPOSE} changed during a refused publish" "a refusal must not half-apply"
fi

# --dry-run needs no authority because it does nothing: it prints the plan,
# including the outward-facing half, and touches neither docker nor the file.
set +e
OUT="$(PATH="$TMP/bin:$PATH" LAKE_PUBLISH_FORCE_NO_CREDENTIAL=1 "$SCRIPT" --push --dry-run 2>&1)"
RC=$?
set -e
AFTER="$(sha256sum "$COMPOSE" | cut -d' ' -f1)"
case "$OUT" in
  *POISONED-DOCKER-WAS-CALLED*) fail "--dry-run invoked docker" "a dry run must print, not do" ;;
  *) pass "--dry-run invokes no docker command" ;;
esac
if [ "$RC" -eq 0 ]; then
  pass "--dry-run exits clean even with no credential"
else
  fail "--dry-run exited ${RC}" "$(printf '%s' "$OUT" | tail -2 | tr '\n' ' ')"
fi
if [ "$BEFORE" = "$AFTER" ]; then
  pass "${COMPOSE} is byte-identical after a dry run"
else
  fail "${COMPOSE} changed during a dry run" "a dry run must write nothing"
fi
case "$OUT" in
  *"docker push ghcr.io/the-anonymous-aspirant/aspirant-lake-duckdb:"*)
    pass "--dry-run prints the exact push it would run" ;;
  *) fail "--dry-run does not print the push command" "a reviewer cannot read the plan" ;;
esac
case "$OUT" in
  *"would REFUSE"*) pass "--dry-run says a real run would be refused here" ;;
  *) fail "--dry-run does not flag the missing credential" \
          "it would read as though publishing were available" ;;
esac

# --- the repin --------------------------------------------------------------
#
# The whole point of the script: the push and the repin are one action. The
# surgery must hit exactly the lake client's line — the compose file pins
# other images by digest too, and a broader substitution would move them.

echo
echo "the repin:"

NEW_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
cp "$COMPOSE" "$TMP/compose.yml"
repin_compose "$TMP/compose.yml" 9.9.9 "$NEW_DIGEST"

if grep -q "${PACKAGE}:9.9.9@${NEW_DIGEST}" "$TMP/compose.yml"; then
  pass "rewrites the lake client line to the new tag@digest"
else
  fail "did not rewrite the lake client line" "$(grep -o "${PACKAGE}[^ ]*" "$TMP/compose.yml" | head -1)"
fi

# Every OTHER line must be untouched. Compare the two files with the lake
# client's own line excluded from both.
if diff <(grep -v 'aspirant-lake-duckdb' "$COMPOSE") \
        <(grep -v 'aspirant-lake-duckdb' "$TMP/compose.yml") >/dev/null; then
  pass "no other line in ${COMPOSE} changed"
else
  fail "the repin moved something other than the lake client image" \
       "the other digest pins in this file are not this script's business"
fi

cp "$TMP/compose.yml" "$TMP/compose.again.yml"
repin_compose "$TMP/compose.again.yml" 9.9.9 "$NEW_DIGEST"
if diff "$TMP/compose.yml" "$TMP/compose.again.yml" >/dev/null; then
  pass "repinning the same tag@digest twice is a no-op"
else
  fail "the repin is not idempotent" "a re-run would corrupt the pin"
fi

if repin_compose "$TMP/compose.again.yml" 9.9.9 "not-a-digest" 2>/dev/null; then
  fail "accepted a non-sha256 digest" "a floating tag is the surprise-upgrade path"
else
  pass "refuses a digest that is not sha256:"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "[PASS] lake client publish: all checks passed"
  exit 0
fi
echo "[FAIL] lake client publish: $fails check(s) failed"
exit 1
