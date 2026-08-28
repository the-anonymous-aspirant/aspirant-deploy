#!/usr/bin/env bash
#
# Build, verify, publish and REPIN the lake client image, as one command.
# Task #4441, following the detection half in #4290.
#
# ## Why this exists
#
# docs/LAKE_SKELETON.md § Republishing the client image carried four commands
# in prose. Prose is what #4134 skipped: it added `cryptography==46.0.3` to
# Dockerfile-LakeDuckDB on 2026-08-24 and did not rebuild, push or repin, so
# `lake-skeleton.sh seed` and `ingest` died at import for three days. #4290
# made that omission LOUD (tests/lake_client_image_unit.sh fails when the pin
# is behind the Dockerfile) but a check can only report; a human still had to
# remember four steps in order.
#
# The load-bearing property here is not automation, it is COUPLING: the push
# and the repin are the same action. You cannot publish with this script and
# forget to repin, because the repin is not a separate step you could skip —
# it is what the script does after the push, and it fails the run if it cannot.
#
# ## What it does NOT do
#
# It does not publish anything on its own. `--push` is outward-facing, so it is
# gated twice: by an explicit flag AND by a probed write:packages credential.
# Without both, nothing leaves this box and nothing is modified. Building and
# verifying (the default) needs neither and is safe for anyone to run.
#
# ## Usage
#
#   ./scripts/publish-lake-client.sh                 # build + verify, no network write
#   ./scripts/publish-lake-client.sh --push --dry-run  # print the publish plan, run none of it
#   ./scripts/publish-lake-client.sh --push          # build, verify, publish, repin, re-verify
#
# The tag is DERIVED from the Dockerfile's `duckdb==` pin, never passed on the
# command line — docs/LAKE_SKELETON.md makes the tag track the DuckDB version,
# and a hand-typed tag is precisely how one tag comes to name two images.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

COMPOSE="${LAKE_COMPOSE_FILE:-docker-compose.lake-skeleton.yml}"
DOCKERFILE="${LAKE_DOCKERFILE:-Dockerfile-LakeDuckDB}"
PACKAGE=ghcr.io/the-anonymous-aspirant/aspirant-lake-duckdb
CANDIDATE=aspirant-lake-duckdb:candidate
VERIFY=./tests/lake_client_image_unit.sh

do_push=0
dry_run=0

die() { echo "[FAIL] $*" >&2; exit 1; }
note() { echo "  $*"; }

usage() {
  sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# --- tag derivation ---------------------------------------------------------

# Exactly one `duckdb==` line, or we stop: two means the parser is guessing
# which one the image installs, none means it has drifted from the Dockerfile.
# Same extraction as tests/lake_client_image_unit.sh, deliberately — if these
# two ever disagree about the version, the check and the publisher are reading
# different files.
derive_tag() {
  local dockerfile="$1" matches n
  matches="$(grep -oE 'duckdb==[0-9][0-9A-Za-z.]*' "$dockerfile" | cut -d= -f3 | sort -u || true)"
  n="$(printf '%s' "$matches" | grep -c . || true)"
  case "$n" in
    1) printf '%s' "$matches" ;;
    0) return 1 ;;
    *) return 2 ;;
  esac
}

# --- repin ------------------------------------------------------------------

# Rewrite ONLY the aspirant-lake-duckdb image line, and only its `tag@digest`
# half. The compose file pins other images by digest too (garage, postgres);
# a broader substitution would silently move them.
repin_compose() {
  local compose="$1" tag="$2" digest="$3" tmp
  case "$digest" in
    sha256:*) ;;
    *) echo "refusing to pin a non-sha256 digest: ${digest}" >&2; return 1 ;;
  esac
  grep -q "aspirant-lake-duckdb:" "$compose" || {
    echo "no aspirant-lake-duckdb image line in ${compose}" >&2; return 1; }
  tmp="$(mktemp)"
  sed -E "s|(image: *${PACKAGE//./\\.}):[^ ]*|\1:${tag}@${digest}|" "$compose" > "$tmp"
  mv "$tmp" "$compose"
}

# --- credential -------------------------------------------------------------

# The same surface system_3's scripts/aspirant_publish_poller.py probes: the
# gh token's scopes ARE the credential, because the push authenticates
# `docker login` with that token. Overridable so the unit suite can exercise
# the refusal path without a real token.
has_write_credential() {
  if [ -n "${LAKE_PUBLISH_FORCE_NO_CREDENTIAL:-}" ]; then return 1; fi
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status 2>&1 | grep -q 'write:packages'
}

run() {
  if [ "$dry_run" -eq 1 ]; then
    echo "  [dry-run] $*"
    return 0
  fi
  "$@"
}

# --- everything above is definitions; everything below acts ----------------

# tests/lake_client_publish_unit.sh sources this file with LAKE_PUBLISH_SOURCE_ONLY=1
# so it exercises derive_tag / repin_compose / has_write_credential THEMSELVES
# rather than keeping a copy of each. A copied helper is exactly how a check and
# the thing it checks drift apart -- which is the failure mode this whole lane
# exists to close. Set this only when sourcing; `return` outside a sourced file
# is an error, which is the loud failure we want if it is ever set otherwise.
if [ -n "${LAKE_PUBLISH_SOURCE_ONLY:-}" ]; then
  return 0
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --push) do_push=1 ;;
    --dry-run) dry_run=1 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
  shift
done


# --- 1. build ---------------------------------------------------------------

TAG="$(derive_tag "$DOCKERFILE")" || case $? in
  1) die "no duckdb== pin found in ${DOCKERFILE} — the tag cannot be derived" ;;
  2) die "more than one duckdb== version in ${DOCKERFILE} — refusing to guess the tag" ;;
esac

echo "lake client image: ${PACKAGE}:${TAG} (derived from ${DOCKERFILE})"

# The credential is probed BEFORE the build, not at step 3. A refusal after a
# multi-minute image build is a refusal the operator waits for, and a script
# that can only tell you it is not allowed to finish after it has started is
# worse than one that says so first. A real --push with no credential must
# therefore touch nothing at all -- no docker call, no file write.
if [ "$do_push" -eq 1 ] && ! has_write_credential; then
  if [ "$dry_run" -eq 1 ]; then
    echo
    echo "  [dry-run] no write:packages on this box: a real --push would REFUSE here."
    echo "  [dry-run] printing the rest of the plan anyway -- a dry run needs no authority,"
    echo "  [dry-run] because it does nothing."
  else
    die "no GHCR write credential: the gh token lacks the write:packages scope.
       Publishing is outward-facing and is the one step this script will not
       improvise. Nothing was built, nothing was pushed, and ${COMPOSE} is
       unchanged.
       See docs/IMAGE_PUBLISH_DECISION.md §2 -- the credential is an open
       operator question, not a bug in this script.
       Run without --push to build and verify a candidate, which needs none."
  fi
fi

echo
echo "1. build"
command -v docker >/dev/null 2>&1 || die "docker is not on PATH"
run docker build -f "$DOCKERFILE" -t "$CANDIDATE" .

# --- 2. verify the candidate BEFORE it is anywhere public -------------------

echo
echo "2. verify the candidate"
if [ "$dry_run" -eq 1 ]; then
  echo "  [dry-run] LAKE_CLIENT_IMAGE=${CANDIDATE} ${VERIFY}"
else
  LAKE_CLIENT_IMAGE="$CANDIDATE" "$VERIFY" \
    || die "the candidate image does not satisfy ${DOCKERFILE} — not publishing it"
fi

if [ "$do_push" -eq 0 ]; then
  echo
  echo "[PASS] candidate built and verified. Nothing was published."
  echo "       Re-run with --push to publish and repin (needs write:packages)."
  exit 0
fi

# --- 3. publish (gated) -----------------------------------------------------

echo
echo "3. publish"
[ "$dry_run" -eq 1 ] || note "write:packages present"
run docker tag "$CANDIDATE" "${PACKAGE}:${TAG}"
run docker push "${PACKAGE}:${TAG}"

# --- 4. repin, in the same breath as the push -------------------------------

echo
echo "4. repin ${COMPOSE}"
if [ "$dry_run" -eq 1 ]; then
  echo "  [dry-run] docker buildx imagetools inspect ${PACKAGE}:${TAG} --format '{{.Manifest.Digest}}'"
  echo "  [dry-run] rewrite the aspirant-lake-duckdb line to :${TAG}@<digest>"
else
  DIGEST="$(docker buildx imagetools inspect "${PACKAGE}:${TAG}" \
              --format '{{.Manifest.Digest}}' 2>/dev/null || true)"
  [ -n "$DIGEST" ] || die "published ${PACKAGE}:${TAG} but could not resolve its digest.
       ${COMPOSE} is UNCHANGED and now points at the previous image — repin by
       hand before merging, or the push is invisible to the deploy."
  repin_compose "$COMPOSE" "$TAG" "$DIGEST" || die "could not repin ${COMPOSE}"
  note "pinned ${PACKAGE}:${TAG}@${DIGEST}"
fi

# --- 5. confirm the PIN, not the local build, satisfies the Dockerfile ------

echo
echo "5. verify the pin"
if [ "$dry_run" -eq 1 ]; then
  echo "  [dry-run] ${VERIFY}"
  echo
  echo "[PASS] dry run: nothing was built, pushed or written."
  exit 0
fi
"$VERIFY" || die "the published pin does not satisfy ${DOCKERFILE}"

echo
echo "[PASS] published ${PACKAGE}:${TAG} and repinned ${COMPOSE}."
echo "       Commit the ${COMPOSE} change — the push is only half of it."
