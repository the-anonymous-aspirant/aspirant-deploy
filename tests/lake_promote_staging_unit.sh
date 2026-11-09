#!/usr/bin/env bash
#
# Test surface for the staging promotion runner, scripts/lake_promote_staging.py.
# Task #9758 (#9546-A2), child E2 of the explorer-upload epic #4121 (#9546).
#
# Two suites, mirroring tests/lake_ingest_unit.sh's split exactly:
#
#   1. tests/lake_promote_staging_roundtrip.py — drives the runner end-to-end
#      against moto S3 and a real DuckDB. Needs cryptography + boto3 + moto +
#      duckdb, none of which the cell's host python carries, so it runs in
#      python:3.11-slim, same as tests/lake_ingest_unit.sh.
#
#   2. the static checks below — run on the host, no docker. They assert the
#      structural property the round-trip cannot: that the runner still
#      IMPORTS the catalog contract, the envelope gate and lake_ingest.py's
#      catalog-store wrapper rather than growing its own copies.
#
# Every KEK exercised here is an EPHEMERAL synthetic key generated inside the
# test process, and every fixture byte is obviously-fake. No production key
# material is touched and nothing is persisted.
#
# Usage: ./tests/lake_promote_staging_unit.sh
#   Requires docker for suite 1. Set LAKE_TEST_IMAGE to override the base image.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${LAKE_TEST_IMAGE:-python:3.11-slim}"
fails=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

# --- suite 2 (host): the runner consumes the contracts, it does not fork them --

echo "static: the runner reuses the shared contracts:"

if grep -q '^from envelope_store import encrypt_for_storage_stream' scripts/lake_promote_staging.py; then
  pass "lake_promote_staging.py encrypts through envelope_store's streaming storage gate"
else
  fail "lake_promote_staging.py does not import encrypt_for_storage_stream" \
       "the crypto must come from scripts/kek, not be re-derived"
fi

if grep -q '^import catalog' scripts/lake_promote_staging.py; then
  pass "lake_promote_staging.py imports the catalog contract"
else
  fail "lake_promote_staging.py does not import the catalog contract" \
       "it must use catalog.asset_row / catalog.run_row"
fi

if grep -qE '^from lake_ingest import .*DuckDBCatalogStore' scripts/lake_promote_staging.py; then
  pass "lake_promote_staging.py reuses lake_ingest.py's catalog-store wrapper"
else
  fail "lake_promote_staging.py does not import DuckDBCatalogStore from lake_ingest" \
       "a second catalog-store implementation could drift from the first (#4270)"
fi

if grep -qE 'AESGCM|Cipher\(|from cryptography' scripts/lake_promote_staging.py; then
  fail "lake_promote_staging.py contains cryptography primitives" \
       "all object crypto belongs in scripts/kek/dek_envelope.py (#4133)"
else
  pass "lake_promote_staging.py contains no cryptography primitives of its own"
fi

if grep -qE '^\s*sha256 VARCHAR, object_key VARCHAR' scripts/lake_promote_staging.py; then
  fail "lake_promote_staging.py re-declares the asset_inventory DDL inline" \
       "it must use catalog.ASSET_INVENTORY_COLUMNS"
else
  pass "lake_promote_staging.py does not re-declare the asset_inventory DDL"
fi

for mount in \
  './scripts/lake_promote_staging.py:/work/promote.py:ro' \
  './scripts/lake_ingest.py:/work/lake_ingest.py:ro' \
  ':/scratch-spool'
do
  if grep -qF "$mount" docker-compose.lake-skeleton.yml; then
    pass "compose mounts ${mount}"
  else
    fail "compose does not mount ${mount}" "the promoter will fail inside the container"
  fi
done

if grep -q 'promote)' scripts/lake-skeleton.sh; then
  pass "lake-skeleton.sh exposes the promote verb"
else
  fail "lake-skeleton.sh has no promote verb" "the compose invocation would be unreproducible"
fi

if grep -q 'promote-spool' scripts/lake-skeleton.sh; then
  pass "lake-skeleton.sh creates the promote spool directory on 'up'"
else
  fail "lake-skeleton.sh does not create the promote-spool directory" \
       "the promoter's spool mount would be an empty root-owned dir on first run"
fi

if [ -f docs/data-lake-design/STAGING_PROMOTION.md ]; then
  pass "the staged-object layout and manifest schema are documented"
else
  fail "docs/data-lake-design/STAGING_PROMOTION.md is missing"
fi

# --- suite 1 (container): the runner actually works -------------------------

echo
if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the promotion round-trip" >&2
else
  # Pinned to the lake client image's own versions (Dockerfile-LakeDuckDB's
  # LAKE_REQUIREMENTS line) — the same pin tests/lake_ingest_unit.sh uses, and
  # for the same reason (system_3 #8810, #9526: an unpinned duckdb wheel dies
  # with "Illegal instruction" on this CPU).
  echo "Running the promotion round-trip in ${IMAGE} ..."
  docker run --rm \
    -v "$PWD:/repo:ro" \
    -w /repo \
    "$IMAGE" \
    sh -c "pip install --quiet --disable-pip-version-check --timeout 120 --retries 5 \
        cryptography==46.0.3 boto3==1.40.47 duckdb==1.5.4 moto \
      && python tests/lake_promote_staging_roundtrip.py" || fails=$((fails + 1))
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "[PASS] staging promotion runner: all checks passed"
  exit 0
fi
echo "[FAIL] staging promotion runner: $fails check(s) failed"
exit 1
