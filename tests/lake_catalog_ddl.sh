#!/usr/bin/env bash
set -euo pipefail

# Runs tests/lake_catalog_ddl.py against a real DuckDB. Task #4270 (#4238-A2).
#
# Split from tests/lake_catalog_unit.sh on purpose: that suite must keep running
# on a bare host with no docker, so the DDL check — which needs an engine — lives
# here instead of being allowed to drag the cheap suite behind a container.
#
# Usage: ./tests/lake_catalog_ddl.sh
#   Requires docker. Set LAKE_TEST_IMAGE to override the base image.

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${LAKE_TEST_IMAGE:-python:3.11-slim}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the catalog DDL checks" >&2
  exit 0
fi

echo "Running the catalog DDL checks in ${IMAGE} ..."
docker run --rm \
  -v "$PWD:/repo:ro" \
  -w /repo \
  "$IMAGE" \
  sh -c "pip install --quiet --disable-pip-version-check duckdb && python tests/lake_catalog_ddl.py"
