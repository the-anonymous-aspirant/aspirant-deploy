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


# --- layer1_check (#4273-B1) --------------------------------------------------
# Mocked findmnt/lsblk rather than the box's real disk layout: a bash function
# shadows the PATH binary of the same name when layer1_check calls it bare, so
# this is deterministic regardless of whether the host running the suite
# happens to have a LUKS mapping anywhere.

assert_rc() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
    echo "[PASS] $label"
  else
    FAIL=$((FAIL + 1))
    echo "[FAIL] $label (want rc=$want, got rc=$got)"
  fi
}

# `rc=0` default + `|| rc=$?`, not `out=$(...); rc=$?` — under this file's own
# `set -e`, a plain failing command substitution assignment would abort the
# suite right here rather than let the next assertion inspect it (the same
# hazard `layer1_check`'s own caller in lake-skeleton.sh avoids the same way).

findmnt() { echo "/dev/mapper/testcrypt"; }
lsblk() { echo "crypt"; }
rc=0; out="$(layer1_check /fake/target)" || rc=$?
assert_rc "a LUKS-backed volume is PASS (rc 0)" "0" "$rc"
assert_eq "and the message says engaged" \
  "1" "$(echo "$out" | grep -c 'PASS.*dm-crypt engaged in the chain')"

findmnt() { echo "/dev/sda"; }
lsblk() { echo "disk"; }
rc=0; out="$(layer1_check /fake/target)" || rc=$?
assert_rc "an unencrypted volume is SKIP (rc 2), not FAIL" "2" "$rc"
assert_eq "and the message says NOT ENGAGED rather than failing" \
  "1" "$(echo "$out" | grep -c 'SKIP.*NOT ENGAGED')"

findmnt() { :; }
rc=0; out="$(layer1_check /fake/target)" || rc=$?
assert_rc "an unresolvable device is FAIL (rc 1)" "1" "$rc"

unset -f findmnt lsblk

# --- explorer_env_check / explorer_env_sync (system_3 #9074) ----------------
# The 2026-10-25 rebuild issued fresh explorer credentials into $ENV_FILE, but
# the deploy .env kept the old ones. The explorer was down for three days and
# nothing reported the drift.

SKEL_ENV="$TMPDIR_TEST/skeleton.env"
DEPLOY_ENV="$TMPDIR_TEST/deploy.env"
NEW_DSN="postgresql://explorer_ro:newpw0123@lake-skeleton-catalog:5432/lake_catalog_skeleton"
cat > "$SKEL_ENV" <<EOF
EXPLORER_S3_ACCESS_KEY=GKnewkey
EXPLORER_S3_SECRET_KEY=newsecret0123
LAKE_CATALOG_RO_DSN=$NEW_DSN
EOF
cat > "$DEPLOY_ENV" <<'EOF'
UNRELATED=keep-me
EXPLORER_S3_ACCESS_KEY=GKoldkey
EXPLORER_S3_SECRET_KEY=oldsecret0123
LAKE_CATALOG_DSN=postgresql://explorer_ro:oldpw0123@lake-skeleton-catalog:5432/lake_catalog_skeleton
EOF
ENV_FILE="$SKEL_ENV"
DEPLOY_ENV_FILE="$DEPLOY_ENV"
mkdir -p "$ROOT"
chmod 644 "$DEPLOY_ENV"  # the mode the cell's deploy .env was found at

rc=0; out="$(explorer_env_check)" || rc=$?
assert_rc "check fails when the deploy .env holds the previous credentials" "1" "$rc"
assert_eq "and names each drifted key" "3" "$(grep -c 'differs from' <<<"$out")"
if grep -qE 'oldsecret|newsecret|oldpw|newpw' <<<"$out"; then
  FAIL=$((FAIL + 1)); echo "[FAIL] check output contains a credential value"
else
  PASS=$((PASS + 1)); echo "[PASS] check output contains no credential value"
fi

explorer_env_sync > /dev/null
assert_eq "sync copies the catalog DSN under the name compose reads" \
  "LAKE_CATALOG_DSN=$NEW_DSN" "$(grep '^LAKE_CATALOG_DSN=' "$DEPLOY_ENV")"
assert_eq "sync copies the secret key" \
  "EXPLORER_S3_SECRET_KEY=newsecret0123" "$(grep '^EXPLORER_S3_SECRET_KEY=' "$DEPLOY_ENV")"
assert_eq "sync leaves other keys alone" "UNRELATED=keep-me" "$(grep '^UNRELATED=' "$DEPLOY_ENV")"
assert_eq "sync keeps a mode-600 backup of the previous file under ROOT" \
  "600" "$(stat -c %a "$ROOT"/deploy-env.bak-*)"
assert_eq "the backup holds the previous credentials" \
  "EXPLORER_S3_ACCESS_KEY=GKoldkey" "$(grep '^EXPLORER_S3_ACCESS_KEY=' "$ROOT"/deploy-env.bak-*)"
rc=0; explorer_env_check > /dev/null || rc=$?
assert_rc "check passes after sync" "0" "$rc"
assert_eq "sync leaves the deploy .env at mode 600" "600" "$(stat -c %a "$DEPLOY_ENV")"
explorer_env_sync > /dev/null
assert_eq "a second sync keeps only the newest backup" \
  "1" "$(find "$ROOT" -maxdepth 1 -name 'deploy-env.bak-*' | wc -l)"

# env_set's value is a sed replacement: | ends it, & and \ are special.
rc=0; ENV_FILE="$TMPDIR_TEST/sed.env" env_set SOME_KEY 'a&b' 2>/dev/null || rc=$?
assert_rc "env_set refuses a value containing &" "1" "$rc"
sed -i '/^EXPLORER_S3_ACCESS_KEY=/d' "$SKEL_ENV"
printf 'EXPLORER_S3_ACCESS_KEY=GK|bad\n' >> "$SKEL_ENV"
before="$(cat "$DEPLOY_ENV")"
rc=0; explorer_env_sync > /dev/null 2>&1 || rc=$?
assert_rc "sync refuses a skeleton value containing |" "1" "$rc"
assert_eq "and writes none of the three" "$before" "$(cat "$DEPLOY_ENV")"
sed -i '/^EXPLORER_S3_ACCESS_KEY=/d' "$SKEL_ENV"
printf 'EXPLORER_S3_ACCESS_KEY=GKnewkey\n' >> "$SKEL_ENV"

# If the skeleton is only half-issued (bootstrap interrupted), sync must not
# overwrite a working deploy .env with a mix of new and placeholder values.
sed -i 's|^EXPLORER_S3_SECRET_KEY=.*|EXPLORER_S3_SECRET_KEY=pending|' "$SKEL_ENV"
before="$(cat "$DEPLOY_ENV")"
rc=0; explorer_env_sync > /dev/null 2>&1 || rc=$?
assert_rc "sync refuses while a skeleton credential is still pending" "1" "$rc"
assert_eq "and writes nothing" "$before" "$(cat "$DEPLOY_ENV")"

DEPLOY_ENV_FILE="$TMPDIR_TEST/absent-deploy.env"
rc=0; explorer_env_sync > /dev/null 2>&1 || rc=$?
assert_rc "sync refuses when the deploy .env does not exist" "1" "$rc"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL failed, $PASS passed"
  exit 1
fi
echo "$PASS passed, 0 failed"
