#!/usr/bin/env bash
#
# Test surface for the Gmail attachment linker, scripts/lake_gmail_link.py
# (system_3 #11557; security c75385 A6 as amended in c75393, A6a-A6c).
#
# Two suites, in the shape of tests/lake_list_staged_unit.sh:
#
#   1. static checks, on the host, no docker: the job and its compose service
#      hold only the linker's own DSN; lake-skeleton.sh creates the table as
#      the catalog owner and grants the role INSERT on it and nothing else.
#
#   2. tests/lake_gmail_link_roundtrip.py against a REAL Postgres: a throwaway
#      postgres:16-alpine on a network of its own, with lake-skeleton.sh's own
#      bootstrap_gmail_linker_role run against it (twice: it is idempotent).
#      The job and the A6c probes then run as the role, from python:3.11-slim
#      with the lake image's duckdb pin and the host's cached postgres
#      extension. A grant question is settled by the attempt, not the docs.
#
# Every id and hash is invented. Passwords are per-run, from openssl, handed to
# containers by --env-file only, and removed with the run. Nothing here reaches
# the real lake: the catalog is a container of this script's own.
#
# Usage: ./tests/lake_gmail_link_unit.sh
#   Requires docker for suite 2. LAKE_TEST_IMAGE overrides the python image.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${LAKE_TEST_IMAGE:-python:3.11-slim}"
JOB=scripts/lake_gmail_link.py
SKEL=scripts/lake-skeleton.sh
COMPOSE=docker-compose.lake-skeleton.yml
fails=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

echo "static: the job holds only its own credentials:"
if grep -qE 'LAKE_S3_|AWS_|LAKE_CATALOG_DSN|LAKE_CATALOG_PASSWORD|STAGING_LISTER|LAKE_KEK' "$JOB"; then
  fail "the job names a key, the owner's catalog credentials or the KEK"
else
  pass "the job names no S3 key, no owner credential and no KEK"
fi
svc="$(awk '/^  gmail-linker:/ { on = 1; print; next } on && /^  [a-z-]+:$/ { exit } on && /^[a-z]/ { exit } on { print }' "$COMPOSE")"
if [ -z "$svc" ]; then
  fail "no gmail-linker service in $COMPOSE"
else
  envs="$(printf '%s\n' "$svc" | sed -n 's/^      \([A-Z_][A-Z0-9_]*\):.*/\1/p' | sort -u | tr '\n' ' ')"
  if [ "$envs" = "LAKE_CATALOG_GMAIL_LINKER_DSN " ]; then
    pass "the gmail-linker service's environment is the linker's DSN alone"
  else
    fail "the gmail-linker service's environment is not the linker's DSN alone" "$envs"
  fi
  if printf '%s\n' "$svc" | grep -q 'GMAIL_LINK_SOURCE.*:/source:ro'; then
    pass "the run's directory is mounted read-only"
  else
    fail "the run's directory is not mounted read-only"
  fi
fi

echo "static: the bootstrap grants the role INSERT on its table and nothing else:"
fn="$(sed -n '/^bootstrap_gmail_linker_role() {/,/^}/p' "$SKEL")"
grants="$(printf '%s\n' "$fn" | grep -E '^GRANT .* TO \$CATALOG_GMAIL_LINKER_ROLE;' | sort | tr '\n' '|')"
want='GRANT CONNECT ON DATABASE lake_catalog_skeleton TO $CATALOG_GMAIL_LINKER_ROLE;|GRANT INSERT ON public.gmail_attachment_links TO $CATALOG_GMAIL_LINKER_ROLE;|GRANT USAGE ON SCHEMA public TO $CATALOG_GMAIL_LINKER_ROLE;|'
if [ "$grants" = "$want" ]; then pass "grants: CONNECT, USAGE on public, INSERT on gmail_attachment_links"; else fail "unexpected grants" "$grants"; fi
if printf '%s\n' "$fn" | grep -q 'REVOKE ALL ON ALL TABLES IN SCHEMA public FROM \$CATALOG_GMAIL_LINKER_ROLE;'; then
  pass "every other table privilege is revoked on each run"
else
  fail "the bootstrap does not revoke the role's other table privileges"
fi
if grep -q '^    bootstrap_gmail_linker_role$' "$SKEL"; then pass "'up' runs the bootstrap"; else fail "'up' does not run the bootstrap"; fi

echo
echo "suite 2: the job and the role against a real Postgres:"
if ! command -v docker >/dev/null 2>&1; then
  echo "[FAIL] docker not available; the grant proofs need a real Postgres" >&2
  exit 1
fi
EXT_DIR="${LAKE_DUCKDB_EXT_DIR:-$HOME/.duckdb/extensions}"
run="glt-$(openssl rand -hex 4)"
work="$(mktemp -d)"
chmod 700 "$work"
cleanup() {
  docker rm -f "$run-pg" >/dev/null 2>&1 || true
  docker network rm "$run" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

owner_pw="$(openssl rand -hex 16)"
ro_pw="$(openssl rand -hex 16)"
printf 'POSTGRES_USER=ducklake\nPOSTGRES_DB=lake_catalog_skeleton\nPOSTGRES_PASSWORD=%s\n' "$owner_pw" >"$work/pg.env"
chmod 600 "$work/pg.env"
docker network create "$run" >/dev/null
docker run -d --name "$run-pg" --network "$run" --network-alias lake-skeleton-catalog \
  --env-file "$work/pg.env" postgres:16-alpine >/dev/null
ready=0
for _ in $(seq 1 60); do
  if docker exec "$run-pg" pg_isready -h 127.0.0.1 -U ducklake -d lake_catalog_skeleton >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { echo "[FAIL] the throwaway postgres did not become ready"; exit 1; }

# What 'up' has made before the linker's bootstrap runs: explorer_ro, and a
# catalog table of the owner's (here a stand-in) for the cross-table probe.
docker exec -i "$run-pg" psql -q -v ON_ERROR_STOP=1 -U ducklake -d lake_catalog_skeleton >/dev/null <<SQL
CREATE ROLE explorer_ro LOGIN PASSWORD '$ro_pw';
GRANT CONNECT ON DATABASE lake_catalog_skeleton TO explorer_ro;
GRANT USAGE ON SCHEMA public TO explorer_ro;
CREATE TABLE public.asset_inventory_standin (id integer NOT NULL);
SQL

# lake-skeleton.sh's own function, with its two seams pointed at this run.
ENV_FILE="$work/lake.env"
: >"$ENV_FILE"
chmod 600 "$ENV_FILE"
CATALOG_RO_ROLE=explorer_ro
CATALOG_GMAIL_LINKER_ROLE=gmail_linker
catalog_psql() { docker exec -i "$run-pg" psql -v ON_ERROR_STOP=1 -U ducklake -d lake_catalog_skeleton "$@"; }
env_set() { sed -i "/^$1=/d" "$ENV_FILE"; printf '%s=%s\n' "$1" "$2" >>"$ENV_FILE"; }
eval "$fn"
if bootstrap_gmail_linker_role && bootstrap_gmail_linker_role; then
  pass "bootstrap_gmail_linker_role runs, and runs again"
else
  fail "bootstrap_gmail_linker_role failed"
fi
{
  grep '^LAKE_CATALOG_GMAIL_LINKER_DSN=' "$ENV_FILE"
  printf 'TEST_OWNER_DSN=postgresql://ducklake:%s@lake-skeleton-catalog:5432/lake_catalog_skeleton\n' "$owner_pw"
  printf 'TEST_RO_DSN=postgresql://explorer_ro:%s@lake-skeleton-catalog:5432/lake_catalog_skeleton\n' "$ro_pw"
} >"$work/run.env"

# Pinned to the lake client image's duckdb (an unpinned one dies on this CPU,
# system_3 #9526), with the host's cached extensions, as compose mounts them.
docker run --rm --network "$run" --env-file "$work/run.env" \
  -v "$PWD:/repo:ro" -v "$EXT_DIR:/root/.duckdb/extensions:ro" -w /repo "$IMAGE" \
  sh -c "pip install --quiet --disable-pip-version-check --root-user-action=ignore --timeout 120 --retries 5 duckdb==1.5.4 \
    && python tests/lake_gmail_link_roundtrip.py" || fails=$((fails + 1))

echo
if [ "$fails" -eq 0 ]; then
  echo "[PASS] gmail linker: all checks passed"
  exit 0
fi
echo "[FAIL] gmail linker: $fails check(s) failed"
exit 1
