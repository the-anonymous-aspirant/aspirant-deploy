#!/usr/bin/env bash
set -euo pipefail

# Unit tests for scripts/lake-skeleton.sh's pure logic — env_set(). No docker
# required.
#
# env_set gets its own suite because the thing it replaced failed SILENTLY. The
# original wrote credentials with:
#
#     sed -i "s|^LAKE_S3_ACCESS_KEY=.*|LAKE_S3_ACCESS_KEY=$key_id|" "$ENV_FILE"
#
# which does nothing at all when the key is absent from the file — and returns
# 0 while doing it. seed_config only writes the env-file template when the file
# does not already exist, so every host provisioned before a new key was added
# to that template hits exactly that path: bootstrap reports success, the
# credential is never written, and the service comes up unauthenticated. That
# is the shape this whole task is about (system_3 #2542), so the fix is tested
# rather than trusted.
#
# Usage: ./tests/lake_skeleton_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export ASPIRANT_LAKE_SKELETON_LIB=1
# Keep the script's own ROOT off any real path; it is not used by env_set but
# the file computes it at source time.
export LAKE_SKELETON_ROOT="$TMPDIR_TEST/root"

# shellcheck disable=SC1091
source ./scripts/lake-skeleton.sh

PASS=0
FAIL=0

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
    echo "[PASS] $label"
  else
    FAIL=$((FAIL + 1))
    echo "[FAIL] $label"
    echo "       want: $want"
    echo "       got : $got"
  fi
}

# --- the regression: appending a key that is not in the file -----------------

ENV_FILE="$TMPDIR_TEST/absent.env"
cat > "$ENV_FILE" <<'EOF'
LAKE_SKELETON_ROOT=/scratch/lake-skeleton
LAKE_S3_ACCESS_KEY=pending
EOF

env_set EXPLORER_S3_ACCESS_KEY "GKtestkeyid"
assert_eq "appends a key absent from the file" \
  "EXPLORER_S3_ACCESS_KEY=GKtestkeyid" \
  "$(grep '^EXPLORER_S3_ACCESS_KEY=' "$ENV_FILE")"

assert_eq "leaves pre-existing lines untouched when appending" \
  "LAKE_S3_ACCESS_KEY=pending" \
  "$(grep '^LAKE_S3_ACCESS_KEY=' "$ENV_FILE")"

# --- updating a key that IS present ------------------------------------------

env_set LAKE_S3_ACCESS_KEY "GKrealkeyid"
assert_eq "updates a key already present" \
  "LAKE_S3_ACCESS_KEY=GKrealkeyid" \
  "$(grep '^LAKE_S3_ACCESS_KEY=' "$ENV_FILE")"

assert_eq "updating does not duplicate the line" \
  "1" \
  "$(grep -c '^LAKE_S3_ACCESS_KEY=' "$ENV_FILE")"

# --- idempotence: bootstrap runs on every 'up' -------------------------------

env_set EXPLORER_S3_ACCESS_KEY "GKtestkeyid"
env_set EXPLORER_S3_ACCESS_KEY "GKtestkeyid"
assert_eq "repeated writes leave exactly one line" \
  "1" \
  "$(grep -c '^EXPLORER_S3_ACCESS_KEY=' "$ENV_FILE")"

# --- values containing sed-hostile characters --------------------------------
# The DSN carries //, : and @. A naive delimiter choice turns this into a
# corrupted file rather than a visible error.

DSN="postgresql://explorer_ro:abc123@lake-skeleton-catalog:5432/lake_catalog_skeleton"
env_set LAKE_CATALOG_RO_DSN "$DSN"
assert_eq "writes a DSN containing slashes, colons and @ verbatim" \
  "LAKE_CATALOG_RO_DSN=$DSN" \
  "$(grep '^LAKE_CATALOG_RO_DSN=' "$ENV_FILE")"

env_set LAKE_CATALOG_RO_DSN "$DSN"
assert_eq "rewriting a DSN in place does not duplicate or mangle it" \
  "LAKE_CATALOG_RO_DSN=$DSN" \
  "$(grep '^LAKE_CATALOG_RO_DSN=' "$ENV_FILE")"

# --- prefix collisions --------------------------------------------------------
# LAKE_S3_ACCESS_KEY and LAKE_S3_ACCESS_KEY_ID would both match a sloppy
# pattern. Anchoring on ^KEY= is what keeps them distinct.

env_set LAKE_S3_ACCESS "short"
assert_eq "a shorter key does not overwrite a longer one sharing its prefix" \
  "LAKE_S3_ACCESS_KEY=GKrealkeyid" \
  "$(grep '^LAKE_S3_ACCESS_KEY=' "$ENV_FILE")"

assert_eq "the shorter key is written as its own line" \
  "LAKE_S3_ACCESS=short" \
  "$(grep '^LAKE_S3_ACCESS=' "$ENV_FILE")"

# --- the read-only credential names the compose file reads -------------------
# Pins the contract between this script and docker-compose.yml. If either side
# renames a variable, the explorer silently gets no credential — the failure
# this task exists to close — so the names are asserted rather than assumed.

for key in EXPLORER_S3_ACCESS_KEY EXPLORER_S3_SECRET_KEY; do
  if grep -q "\${$key" docker-compose.yml; then
    PASS=$((PASS + 1)); echo "[PASS] docker-compose.yml reads $key"
  else
    FAIL=$((FAIL + 1)); echo "[FAIL] docker-compose.yml does not read $key"
  fi
done

assert_eq "the read-only key name is the one the bootstrap issues" \
  "lake-skeleton-explorer-ro" "$RO_KEY_NAME"
assert_eq "the read-only catalog role name is the one the bootstrap issues" \
  "explorer_ro" "$CATALOG_RO_ROLE"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL failed, $PASS passed"
  exit 1
fi
echo "$PASS passed, 0 failed"
