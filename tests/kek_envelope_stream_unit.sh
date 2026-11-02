#!/usr/bin/env bash
#
# Streaming AOBJ writer test (scripts/kek/dek_envelope.py::encrypt_object_stream)
# -- task #9757 (#9546-A1), DATA_LAKE_DESIGN.md §9 layer 2.
#
# Proves the streamed object is byte-identical to encrypt_object's layout and
# that 512 MiB streams through in bounded memory. Runs in python:3.11-slim with
# `cryptography`, like tests/kek_envelope_unit.sh, because the cell's host
# python does not carry it. Synthetic keys only; nothing persists. Kept apart
# from the module's --self-test, which doubles as the operator's recovery drill
# and should stay quick.
#
# Usage: ./tests/kek_envelope_stream_unit.sh
#   Requires docker. Set KEK_TEST_IMAGE to override the base image.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${KEK_TEST_IMAGE:-python:3.11-slim}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the streaming envelope test" >&2
  exit 0
fi

echo "Running the streaming AOBJ writer test in ${IMAGE} ..."
docker run --rm \
  -v "$PWD:/repo:ro" \
  -w /repo \
  "$IMAGE" \
  sh -c "pip install --quiet --disable-pip-version-check cryptography \
    && ( cd scripts/kek && python dek_envelope.py --self-test ) \
    && python tests/kek_envelope_stream_test.py"
