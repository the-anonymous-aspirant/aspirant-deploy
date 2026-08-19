#!/usr/bin/env bash
#
# Unit / round-trip test for the layer-2 wrapped-DEK format
# (scripts/kek/dek_envelope.py) -- DATA_LAKE_DESIGN.md §9 layer 2, task #4133.
#
# The reference implementation depends on `cryptography`, which the cell's host
# python does not carry (and aspirant-deploy has no Makefile, so `make verify`
# is not the surface here -- the container is). This runs the module's own
# --self-test inside python:3.11-slim with `cryptography` pip-installed, exactly
# the way the ingest runner (child D, #4134) will carry it.
#
# The self-test uses an EPHEMERAL synthetic KEK generated inside the container;
# it never touches the production KEK and persists nothing. It exercises the
# happy-path round-trip (DEK -> wrap -> object encrypt -> decrypt -> unwrap) and
# the three tamper/wrong-key negative cases.
#
# Usage: ./tests/kek_envelope_unit.sh
#   Requires docker. Set KEK_TEST_IMAGE to override the base image.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${KEK_TEST_IMAGE:-python:3.11-slim}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the crypto self-test" >&2
  exit 0
fi

echo "Running the wrapped-DEK round-trip self-test in ${IMAGE} ..."
docker run --rm \
  -v "$PWD/scripts/kek:/kek:ro" \
  -w /kek \
  "$IMAGE" \
  sh -c "pip install --quiet --disable-pip-version-check cryptography && python dek_envelope.py --self-test"
