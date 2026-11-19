#!/usr/bin/env bash
#
# Test surface for the staging lister, scripts/lake_list_staged.py (system_3
# #11615, #11558-D1; security c71659 on #11611, c71693 on #11615).
#
# Two suites, in the shape of tests/lake_promote_staging_unit.sh:
#
#   1. static checks, on the host, no docker: the job and its compose service
#      hold only the lister's own credentials; the job fetches manifests and
#      nothing else; lake-skeleton.sh issues the key, creates the tables as
#      the catalog owner and grants the role only what one run needs.
#
#   2. tests/lake_list_staged_roundtrip.py: the job end to end against moto S3
#      and a real DuckDB, in python:3.11-slim with the lake image's pins.
#
# Every fixture is obviously fake. Nothing here reaches the real lake.
#
# Usage: ./tests/lake_list_staged_unit.sh
#   Requires docker for suite 2. Set LAKE_TEST_IMAGE to override the base image.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${LAKE_TEST_IMAGE:-python:3.11-slim}"
JOB=scripts/lake_list_staged.py
SKEL=scripts/lake-skeleton.sh
COMPOSE=docker-compose.lake-skeleton.yml
fails=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

echo "static: the job holds only its own credentials:"
if grep -qE 'LAKE_S3_ACCESS_KEY|LAKE_S3_SECRET_KEY|AWS_ACCESS_KEY_ID|LAKE_CATALOG_DSN|LAKE_CATALOG_PASSWORD' "$JOB"; then
  fail "the job names the runner's key or the owner's catalog credentials"
else
  pass "the job names neither the runner's key nor the owner's catalog credentials"
fi

# The staging-lister service block: from its key line to the next top-level
# service or the networks block.
svc="$(awk '/^  staging-lister:/{f=1} f&&/^(  [a-z-]+:|networks:)/&&!/^  staging-lister:/{exit} f' "$COMPOSE")"
if [ -z "$svc" ]; then
  fail "the compose file has a staging-lister service"
else
  pass "the compose file has a staging-lister service"
  if printf '%s\n' "$svc" | grep -qE 'LAKE_S3_ACCESS_KEY|LAKE_S3_SECRET_KEY|AWS_ACCESS_KEY_ID|LAKE_CATALOG_DSN|LAKE_CATALOG_PASSWORD|EXPLORER_S3|LAKE_KEK'; then
    fail "the staging-lister service carries a credential that is not its own"
  else
    pass "the staging-lister service carries only the lister's own credentials"
  fi
  if printf '%s\n' "$svc" | grep -qE 'lake_list_staged.py:/work/list_staged.py:ro'; then
    pass "the service mounts only the job, read-only"
  else
    fail "the service mounts the job read-only at /work/list_staged.py"
  fi
fi

echo "static: the job reads listings and manifests only:"
gets="$(grep -cE 'get_object\(' "$JOB")"
if [ "$gets" = 1 ] && grep -qE 'get_object\(Bucket=staging_bucket, Key=manifest_key\(upload_id\)\)' "$JOB"; then
  pass "its one get_object reads manifest_key(upload_id)"
else
  fail "the job has exactly one get_object, on the manifest key" "found $gets"
fi
if grep -qE 'put_object\(|delete_object\(|copy_object\(|TRUNCATE TABLE|execute\(f?"TRUNCATE' "$JOB"; then
  fail "the job writes or deletes an object, or truncates a table"
else
  pass "the job writes no object, deletes none and truncates nothing"
fi

echo "static: lake-skeleton.sh issues the key, the tables and the role as ruled:"
if grep -qE 'bucket allow --read "\$STAGING_BUCKET" --key "\$LISTER_KEY_NAME"' "$SKEL" &&
   grep -qE 'bucket deny --write "\$STAGING_BUCKET" --key "\$LISTER_KEY_NAME"' "$SKEL" &&
   grep -qE 'bucket deny --read --write "\$BUCKET" --key "\$LISTER_KEY_NAME"' "$SKEL"; then
  pass "the lister key: read on staging, write denied there, nothing on bronze"
else
  fail "the lister key's grants and denials are all asserted"
fi
if grep -qE 'bucket allow [^"]*--write[^"]*"\$STAGING_BUCKET" --key "\$LISTER_KEY_NAME"|allow[^"]*"\$BUCKET" --key "\$LISTER_KEY_NAME"' "$SKEL"; then
  fail "the lister key is granted a write or bronze"
else
  pass "the lister key is granted no write and nothing on bronze"
fi
fn="$(awk '/^bootstrap_staging_lister_role\(\)/{f=1} f; f&&/^}/{exit}' "$SKEL")"
if printf '%s\n' "$fn" | grep -qE 'CREATE TABLE IF NOT EXISTS public.staged_uploads \(' &&
   printf '%s\n' "$fn" | grep -qE 'CREATE TABLE IF NOT EXISTS public.staged_uploads_read \('; then
  pass "both tables are created in the owner's catalog session"
else
  fail "both tables are created by bootstrap_staging_lister_role"
fi
if printf '%s\n' "$fn" | grep -qE 'GRANT SELECT, INSERT, DELETE ON public.staged_uploads TO' &&
   printf '%s\n' "$fn" | grep -qE 'GRANT SELECT, INSERT, UPDATE ON public.staged_uploads_read TO'; then
  pass "the role is granted exactly what one run needs"
else
  fail "the role's two GRANTs match the ruling"
fi
if printf '%s\n' "$fn" | grep -qE 'TRUNCATE|GRANT ALL|ALTER TABLE .* OWNER'; then
  fail "the role is granted TRUNCATE, ALL, or ownership"
else
  pass "the role gets no TRUNCATE, no ALL and no ownership"
fi
if grep -qE '^  list-staged\)' "$SKEL" && grep -qE 'run --rm staging-lister /work/list_staged.py' "$SKEL"; then
  pass "lake-skeleton.sh list-staged runs the job in its own service"
else
  fail "lake-skeleton.sh has a list-staged verb on the staging-lister service"
fi

echo "round trip:"
if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the round trip" >&2
else
  # Pinned to the lake client image's versions, as the promotion runner's
  # suite is (system_3 #8810, #9526: an unpinned duckdb dies on this CPU).
  docker run --rm \
    -v "$PWD:/repo:ro" \
    -w /repo \
    "$IMAGE" \
    sh -c "pip install --quiet --disable-pip-version-check --timeout 120 --retries 5 \
        boto3==1.40.47 duckdb==1.5.4 pytz==2025.2 moto \
      && python tests/lake_list_staged_roundtrip.py" || fails=$((fails + 1))
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "[PASS] staging lister: all checks passed"
  exit 0
fi
echo "[FAIL] staging lister: $fails check(s) failed"
exit 1
