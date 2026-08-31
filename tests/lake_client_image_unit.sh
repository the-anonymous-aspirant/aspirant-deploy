#!/usr/bin/env bash
#
# Test surface for the lake client image — the one component of the skeleton
# stack that had none. Task #4290.
#
# `Dockerfile-LakeDuckDB` builds a first-party image that
# docker-compose.lake-skeleton.yml BUILDS locally (#4475, previously a pinned
# GHCR digest). The failure this suite exists to catch — #4134 added
# `cryptography==46.0.3` to the Dockerfile on 2026-08-24 and left
# `lake-skeleton.sh seed`/`ingest` dying at `import` for three days because the
# pinned digest was never republished — is now structurally impossible, since
# the running image is always built from the current Dockerfile. What remains
# worth checking is that the image the skeleton builds actually satisfies the
# Dockerfile's pins and extensions.
#
# Two legs:
#
#   1. the static checks below — host, no docker. They assert the duckdb service
#      builds from Dockerfile-LakeDuckDB (not a floating tag or stray pin), so a
#      change to the Dockerfile is what the skeleton runs.
#
#   2. tests/lake_client_image_probe.py — builds the image locally, then runs
#      INSIDE it with the repo mounted read-only, and asserts that every
#      `name==version` the Dockerfile pins resolves in the image at that exact
#      version, and that every extension it bakes still loads. Derived from the
#      Dockerfile, so it covers the NEXT dependency too rather than only this one.
#
# The probe runs with --network none on purpose: DuckDB will fetch a missing
# extension from extensions.duckdb.org and report success, which would turn the
# check the image exists to satisfy into a check of the dev box's uplink.
#
# Usage: ./tests/lake_client_image_unit.sh
#   Requires docker for leg 2. Set LAKE_CLIENT_IMAGE to probe a pre-built image
#   instead of building it here (e.g. to reuse an image the harness just built).

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

# --- leg 1 (host): the duckdb service builds from the Dockerfile -------------

echo "static: the compose duckdb service builds ${DOCKERFILE}:"

if grep -qE "dockerfile:[[:space:]]*${DOCKERFILE}" "$COMPOSE"; then
  pass "compose builds the client image from ${DOCKERFILE}"
else
  fail "compose does not build the client image from ${DOCKERFILE}" \
       "the duckdb service must carry a build: block naming the Dockerfile (#4475)"
fi

# A stale ghcr pin left alongside build: would silently win on some compose
# versions and re-introduce the un-republished-digest stall this switch removes.
if grep -qE 'ghcr\.io/[^ ]*aspirant-lake-duckdb' "$COMPOSE"; then
  fail "a ghcr aspirant-lake-duckdb pin is still present in ${COMPOSE}" \
       "the image is built locally now (#4475); remove the stale digest pin"
else
  pass "no stale ghcr aspirant-lake-duckdb pin remains"
fi

# The Dockerfile must still pin duckdb — the probe checks the built image
# against it; a missing pin means the parser or the Dockerfile drifted.
DUCKDB_VERSION="$(grep -oE 'duckdb==[0-9][0-9A-Za-z.]*' "$DOCKERFILE" | head -1 | cut -d= -f3 || true)"
if [ -z "$DUCKDB_VERSION" ]; then
  fail "no duckdb== pin found in ${DOCKERFILE}" "the parser has drifted from the Dockerfile"
else
  pass "Dockerfile pins duckdb==${DUCKDB_VERSION}"
fi

# --- leg 2 (container): the built image satisfies the Dockerfile -------------

echo
if ! command -v docker >/dev/null 2>&1; then
  skip "docker not available; the built image was NOT checked"
else
  IMAGE="${LAKE_CLIENT_IMAGE:-aspirant-lake-duckdb:local}"
  if [ -z "${LAKE_CLIENT_IMAGE:-}" ]; then
    echo "Building ${IMAGE} from ${DOCKERFILE} ..."
    docker build -q -f "$DOCKERFILE" -t "$IMAGE" . >/dev/null || { fail "the client image failed to build from ${DOCKERFILE}"; IMAGE=""; }
  fi
  if [ -n "$IMAGE" ] && ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    skip "image ${IMAGE} not present and not built; the built image was NOT checked"
    IMAGE=""
  fi
  if [ -n "$IMAGE" ]; then
    echo "Probing ${IMAGE} ..."
    docker run --rm --network none \
      -v "$PWD:/repo:ro" \
      --entrypoint python \
      "$IMAGE" \
      /repo/tests/lake_client_image_probe.py || fails=$((fails + 1))
  fi
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "[PASS] lake client image: all checks passed$(skipnote)"
  exit 0
fi
echo "[FAIL] lake client image: $fails check(s) failed$(skipnote)"
exit 1
