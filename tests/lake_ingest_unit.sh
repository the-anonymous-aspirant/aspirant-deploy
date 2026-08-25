#!/usr/bin/env bash
#
# Test surface for the real-data ingest runner, scripts/lake_ingest.py.
# Task #4271 (#4238-B1), layer 1 of the phase-1 real-data epic #4238.
#
# Two suites, and the split is deliberate:
#
#   1. tests/lake_ingest_roundtrip.py — drives the runner end-to-end against
#      moto S3 and a real DuckDB. Needs cryptography + boto3 + moto + duckdb,
#      none of which the cell's host python carries, so it runs in
#      python:3.11-slim like tests/envelope_ingest_unit.sh and
#      tests/lake_catalog_ddl.sh (aspirant-deploy has no Makefile; the container
#      is the test surface, per CONVENTIONS.md).
#
#   2. the static checks below — run on the host, no docker. They assert the
#      structural property the round-trip cannot: that the runner still IMPORTS
#      the catalog contract and the envelope gate rather than growing its own
#      copy. A local re-derivation of the crypto or the DDL would pass every
#      behavioural test in suite 1 while forking the contract, which is exactly
#      the drift #4270 moved the schema out of the fixtures loader to prevent.
#
# Every KEK exercised here is an EPHEMERAL synthetic key generated inside the
# test process, and every fixture byte is obviously-fake. No production key
# material is touched and nothing is persisted.
#
# Usage: ./tests/lake_ingest_unit.sh
#   Requires docker for suite 1. Set LAKE_TEST_IMAGE to override the base image.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${LAKE_TEST_IMAGE:-python:3.11-slim}"
fails=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

# --- suite 2 (host): the runner consumes the contracts, it does not fork them --

echo "static: the runner reuses the shared contracts:"

if grep -q '^from envelope_store import storage_body_and_wrapped_dek' scripts/lake_ingest.py; then
  pass "lake_ingest.py encrypts through envelope_store's storage gate"
else
  fail "lake_ingest.py does not import storage_body_and_wrapped_dek" \
       "the crypto must come from scripts/kek, not be re-derived"
fi

if grep -q '^import catalog' scripts/lake_ingest.py; then
  pass "lake_ingest.py imports the catalog contract"
else
  fail "lake_ingest.py does not import the catalog contract" \
       "it must use catalog.asset_row / catalog.run_row"
fi

# The specific re-derivations worth naming. `Cipher(`/`AESGCM` would mean the
# runner grew its own crypto; the DDL prefix would mean it grew its own schema.
if grep -qE 'AESGCM|Cipher\(|from cryptography' scripts/lake_ingest.py; then
  fail "lake_ingest.py contains cryptography primitives" \
       "all object crypto belongs in scripts/kek/dek_envelope.py (#4133)"
else
  pass "lake_ingest.py contains no cryptography primitives of its own"
fi

if grep -qE '^\s*sha256 VARCHAR, object_key VARCHAR' scripts/lake_ingest.py; then
  fail "lake_ingest.py re-declares the asset_inventory DDL inline" \
       "it must use catalog.ASSET_INVENTORY_COLUMNS"
else
  pass "lake_ingest.py does not re-declare the asset_inventory DDL"
fi

# The runner reaches scripts/kek and scripts/lake only because compose mounts
# them beside it. Without the mounts an ingest dies on ImportError inside a
# container, which is a slow and confusing way to find out.
for mount in './scripts/lake_ingest.py:/work/ingest.py:ro' './scripts/kek:/work/kek:ro' './scripts/lake:/work/lake:ro'; do
  if grep -qF "$mount" docker-compose.lake-skeleton.yml; then
    pass "compose mounts ${mount%%:*}"
  else
    fail "compose does not mount ${mount%%:*}" "the ingest will fail inside the container"
  fi
done

if grep -q 'ingest)' scripts/lake-skeleton.sh; then
  pass "lake-skeleton.sh exposes the ingest verb"
else
  fail "lake-skeleton.sh has no ingest verb" "the compose invocation would be unreproducible"
fi

# The manifest schema is a cross-repo contract: #4238-B2 reads these rows from
# aspirant-explorer, and #4238-C1 verifies them. A schema documented only in a
# docstring is not one.
if [ -f docs/data-lake-design/REAL_DATA_INGEST.md ]; then
  pass "the manifest schema and failure taxonomy are documented"
else
  fail "docs/data-lake-design/REAL_DATA_INGEST.md is missing"
fi

# --- suite 1 (container): the runner actually works -------------------------

echo
if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the ingest round-trip" >&2
else
  echo "Running the ingest round-trip in ${IMAGE} ..."
  docker run --rm \
    -v "$PWD:/repo:ro" \
    -w /repo \
    "$IMAGE" \
    sh -c "pip install --quiet --disable-pip-version-check cryptography boto3 moto duckdb \
      && python tests/lake_ingest_roundtrip.py" || fails=$((fails + 1))
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "[PASS] lake ingest runner: all checks passed"
  exit 0
fi
echo "[FAIL] lake ingest runner: $fails check(s) failed"
exit 1
