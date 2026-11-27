#!/usr/bin/env bash
#
# Test surface for the lake verify's content checks, scripts/lake/skeleton_content.py
# (system_3 #12521).
#
#   1. the static checks below, on the host: the verify goes through the module
#      and the shared constants rather than carrying its own copies.
#   2. tests/lake_skeleton_content.py, in python:3.11-slim with the lake client
#      image's pinned DuckDB: each check against a fixtures-only lake, a lake
#      holding fixtures beside real rows, and a lake of real rows only.
#
# Every value is invented. No lake, key or credential is touched.
#
# Usage: ./tests/lake_skeleton_content_unit.sh
#   Requires docker for suite 2. Set LAKE_TEST_IMAGE to override the base image.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
IMAGE="${LAKE_TEST_IMAGE:-python:3.11-slim}"
fails=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

echo "static: one source for each shared fact:"
if grep -q '^import skeleton_content' scripts/lake_skeleton_verify.py; then
  pass "the verify imports the content checks"
else
  fail "the verify does not import skeleton_content"
fi
if grep -q '^from dek_envelope import AOBJ_MAGIC' scripts/lake_skeleton_verify.py; then
  pass "the verify takes the encrypted-object header from the envelope format"
else
  fail "the verify does not import AOBJ_MAGIC from dek_envelope"
fi
if grep -q '^SYNTHETIC_DATASET_ID = catalog.SYNTHETIC_DATASET_ID' scripts/lake_skeleton_fixtures.py; then
  pass "the seed writes the catalog contract's fixture dataset id"
else
  fail "lake_skeleton_fixtures.py carries its own SYNTHETIC_DATASET_ID"
fi
if grep -qE 'hashlib\.sha256\(body\)|sensitivity = .high.\").fetchone|date_part\(.year., ingested_at\) <> 2999' scripts/lake_skeleton_verify.py; then
  fail "the verify still runs a fixture-shape check over every row" "it belongs in skeleton_content, scoped to fixtures"
else
  pass "no fixture-shape check in the verify runs over every row"
fi

echo
if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the content checks' tests" >&2
else
  # Pinned to the lake client image's DuckDB (Dockerfile-LakeDuckDB's
  # LAKE_REQUIREMENTS line), as tests/lake_promote_staging_unit.sh is: an
  # unpinned duckdb wheel dies with "Illegal instruction" on this CPU
  # (system_3 #8810, #9526).
  echo "Running the content checks' tests in ${IMAGE} ..."
  docker run --rm \
    -v "$PWD:/repo:ro" \
    -w /repo \
    "$IMAGE" \
    sh -c "pip install --quiet --disable-pip-version-check --timeout 120 --retries 5 duckdb==1.5.4 \
      && python tests/lake_skeleton_content.py" || fails=$((fails + 1))
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "[PASS] lake verify content checks: all checks passed"
  exit 0
fi
echo "[FAIL] lake verify content checks: $fails check(s) failed"
exit 1
