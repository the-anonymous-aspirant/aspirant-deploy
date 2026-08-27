#!/usr/bin/env bash
#
# Test surface for the lake client image — the one component of the skeleton
# stack that had none. Task #4290.
#
# `Dockerfile-LakeDuckDB` builds a first-party image that
# docker-compose.lake-skeleton.yml consumes by digest. Nothing rebuilds it,
# nothing republishes it, and until this file nothing compared the two. The
# result, live for three days: #4134 added `cryptography==46.0.3` to the
# Dockerfile on 2026-08-24 and did not repin, so `lake-skeleton.sh seed` and
# `lake-skeleton.sh ingest` both died at `import` inside the container while
# every suite in tests/ stayed green — they all pip-install into
# python:3.11-slim at test time and none had ever run the pinned image.
#
# Two legs:
#
#   1. the static checks below — host, no docker. They assert the pin is still
#      a pin, and that its tag has not drifted from the version the Dockerfile
#      installs.
#
#   2. tests/lake_client_image_probe.py — runs INSIDE the pinned image with the
#      repo mounted read-only, and asserts that every `name==version` the
#      Dockerfile pins resolves in the image at that exact version, and that
#      every extension it bakes still loads. Derived from the Dockerfile, so it
#      covers the NEXT dependency too rather than only this one.
#
# The probe runs with --network none on purpose: DuckDB will fetch a missing
# extension from extensions.duckdb.org and report success, which would turn the
# check the image exists to satisfy into a check of the dev box's uplink.
#
# This suite is expected to be RED whenever the published image is behind the
# Dockerfile. That is the report, not a broken test — see
# docs/LAKE_SKELETON.md § Republishing the client image for what clears it.
#
# Usage: ./tests/lake_client_image_unit.sh
#   Requires docker for leg 2. Set LAKE_CLIENT_IMAGE to probe a locally built
#   image instead of the pinned one (e.g. to confirm a rebuild is good BEFORE
#   pushing it).

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

COMPOSE=docker-compose.lake-skeleton.yml
DOCKERFILE=Dockerfile-LakeDuckDB
fails=0
skips=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }
skip() { echo "  [SKIP] $1"; skips=$((skips + 1)); }
skipnote() { [ "$skips" -gt 0 ] && printf ' (%d skipped)' "$skips"; return 0; }

# --- leg 1 (host): the pin is a pin, and its tag matches the Dockerfile ------

echo "static: the compose pin agrees with ${DOCKERFILE}:"

PIN="$(grep -oE 'ghcr\.io/[^ ]*aspirant-lake-duckdb:[^ ]+' "$COMPOSE" | head -1 || true)"

if [ -z "$PIN" ]; then
  fail "no aspirant-lake-duckdb image line in ${COMPOSE}" \
       "this suite cannot find what it is meant to check"
  echo
  echo "[FAIL] lake client image: $fails check(s) failed"
  exit 1
fi
pass "compose names the client image: ${PIN}"

case "$PIN" in
  *@sha256:*) pass "the client image is digest-pinned" ;;
  *) fail "the client image is not digest-pinned" \
          "a floating tag reintroduces the surprise-upgrade path docs/LAKE_SKELETON.md rejects" ;;
esac

# The tag carries the DuckDB version by convention (`:1.5.4`). A duckdb bump in
# the Dockerfile without a tag bump leaves two images sharing one tag, which is
# how a rollback stops being possible.
PIN_TAG="${PIN##*aspirant-lake-duckdb:}"
PIN_TAG="${PIN_TAG%%@*}"
DUCKDB_VERSION="$(grep -oE 'duckdb==[0-9][0-9A-Za-z.]*' "$DOCKERFILE" | head -1 | cut -d= -f3 || true)"

if [ -z "$DUCKDB_VERSION" ]; then
  fail "no duckdb== pin found in ${DOCKERFILE}" "the parser has drifted from the Dockerfile"
elif [ "$PIN_TAG" = "$DUCKDB_VERSION" ]; then
  pass "image tag :${PIN_TAG} matches duckdb==${DUCKDB_VERSION}"
else
  fail "image tag is :${PIN_TAG} but the Dockerfile installs duckdb==${DUCKDB_VERSION}" \
       "bump the tag with the version, so one tag never names two images"
fi

# --- leg 2 (container): the published image satisfies the Dockerfile --------

IMAGE="${LAKE_CLIENT_IMAGE:-$PIN}"

echo
if ! command -v docker >/dev/null 2>&1; then
  skip "docker not available; the published image was NOT checked"
elif ! docker image inspect "$IMAGE" >/dev/null 2>&1 && ! docker pull "$IMAGE" >/dev/null 2>&1; then
  skip "could not pull ${IMAGE}; the published image was NOT checked"
else
  echo "Probing ${IMAGE} ..."
  docker run --rm --network none \
    -v "$PWD:/repo:ro" \
    --entrypoint python \
    "$IMAGE" \
    /repo/tests/lake_client_image_probe.py || fails=$((fails + 1))
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "[PASS] lake client image: all checks passed$(skipnote)"
  exit 0
fi
echo "[FAIL] lake client image: $fails check(s) failed$(skipnote)"
exit 1
