#!/usr/bin/env bash
#
# Unit / round-trip test for the layer-2 ingest-side envelope machinery:
# scripts/kek/kek_loader.py (fail-closed KEK loading) and
# scripts/kek/envelope_store.py (encrypt-for-storage / decrypt-from-storage over
# the wrapped-DEK format). DATA_LAKE_DESIGN.md §9 layer 2, task #4134 (#4120-D).
#
# Like tests/kek_envelope_unit.sh, this runs in python:3.11-slim with
# `cryptography` pip-installed, because the cell's host python does not carry it
# and aspirant-deploy has no Makefile (the container is the test surface, per
# CONVENTIONS.md). It mounts scripts/kek read-only and runs each module's own
# --self-test.
#
# Every KEK here is an EPHEMERAL synthetic key generated inside the container:
# no production key material is touched and nothing is persisted. The operator's
# real custody drill (encrypt real data with the off-cell KEK) is separate and
# gated on the ceremony (#4133).
#
# Usage: ./tests/envelope_ingest_unit.sh
#   Requires docker. Set KEK_TEST_IMAGE to override the base image.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${KEK_TEST_IMAGE:-python:3.11-slim}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the envelope self-tests" >&2
  exit 0
fi

echo "Running the ingest-envelope + KEK-loader self-tests in ${IMAGE} ..."
docker run --rm \
  -v "$PWD:/repo:ro" \
  -w /repo \
  "$IMAGE" \
  sh -c "pip install --quiet --disable-pip-version-check cryptography boto3 moto \
    && ( cd scripts/kek \
         && python dek_envelope.py --self-test \
         && python kek_loader.py --self-test \
         && python envelope_store.py --self-test ) \
    && python tests/envelope_ingest_s3_roundtrip.py"
