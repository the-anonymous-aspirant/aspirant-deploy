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

# --- no value in any argv (system_3 #11381; security c69918 on #11368) --------
# env_set used to run `sed -i "s|^KEY=.*|KEY=$value|"`, so every credential it
# wrote sat in sed's /proc/<pid>/cmdline. Shim every external command env_set,
# bootstrap_catalog_role or explorer_env_sync could reach on PATH: each shim
# logs its argv and then runs the real binary. Builtins never reach a shim,
# which is the point. The positive controls below prove the shims are on the
# path that runs, so an empty match is not a vacuous pass.

SHIM_DIR="$TMPDIR_TEST/shims"
ARGV_LOG="$TMPDIR_TEST/argv.log"
mkdir -p "$SHIM_DIR"
: > "$ARGV_LOG"
for cmd in sed awk grep cut cat tee cp mv mktemp chmod dirname install tail openssl perl python3; do
  real="$(type -P "$cmd" 2>/dev/null)" || continue
  cat > "$SHIM_DIR/$cmd" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$cmd" "\$*" >> "$ARGV_LOG"
exec "$real" "\$@"
EOF
  chmod +x "$SHIM_DIR/$cmd"
done
ORIG_PATH="$PATH"

PROBE_VALUE="c0ffee5ecretprobe0123456789abcdef"
ENV_FILE="$TMPDIR_TEST/argv.env"
printf 'OTHER=1\nPROBE_KEY=old\n' > "$ENV_FILE"
chmod 600 "$ENV_FILE"
PATH="$SHIM_DIR:$ORIG_PATH"
env_set PROBE_KEY "$PROBE_VALUE"
env_set PROBE_NEW "$PROBE_VALUE"
PATH="$ORIG_PATH"
assert_eq "env_set updates a present key" "PROBE_KEY=$PROBE_VALUE" "$(grep '^PROBE_KEY=' "$ENV_FILE")"
assert_eq "env_set appends an absent key" "PROBE_NEW=$PROBE_VALUE" "$(grep '^PROBE_NEW=' "$ENV_FILE")"
assert_eq "env_set keeps the other lines" "OTHER=1" "$(grep '^OTHER=' "$ENV_FILE")"
assert_eq "env_set keeps the file's mode" "600" "$(stat -c %a "$ENV_FILE")"
assert_eq "env_set keeps the file's owner" "$(id -u)" "$(stat -c %u "$ENV_FILE")"
chmod 640 "$ENV_FILE"
env_set PROBE_KEY "$PROBE_VALUE"
assert_eq "env_set keeps a mode other than 600" "640" "$(stat -c %a "$ENV_FILE")"
chmod 600 "$ENV_FILE"
assert_eq "env_set leaves no temp copy behind" "0" \
  "$(find "$TMPDIR_TEST" -maxdepth 1 -name '.env_set.*' | wc -l)"
assert_eq "positive control: the shims saw env_set's mktemp and mv" "2 2" \
  "$(grep -c '^mktemp ' "$ARGV_LOG") $(grep -c '^mv ' "$ARGV_LOG")"
assert_eq "no external command env_set ran had the value in its argv" "0" \
  "$(grep -cF "$PROBE_VALUE" "$ARGV_LOG" || true)"

# The explorer_ro rotation (the rotate-explorer-ro verb): 'pending' makes
# bootstrap_catalog_role generate a password, ALTER the role over stdin and
# write the password and DSN. catalog_psql is stubbed to capture that stdin.
SQL_CAPTURE="$TMPDIR_TEST/rotate.sql"
ENV_FILE="$TMPDIR_TEST/rotate.env"
printf 'LAKE_CATALOG_RO_PASSWORD=0ld0ld0ld\nLAKE_CATALOG_RO_DSN=postgresql://explorer_ro:0ld0ld0ld@lake-skeleton-catalog:5432/lake_catalog_skeleton\n' > "$ENV_FILE"
chmod 600 "$ENV_FILE"
: > "$ARGV_LOG"
(
  catalog_psql() { cat > "$SQL_CAPTURE"; }
  PATH="$SHIM_DIR:$ORIG_PATH"
  env_set LAKE_CATALOG_RO_PASSWORD pending
  bootstrap_catalog_role
)
new_pw="$(grep '^LAKE_CATALOG_RO_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
assert_eq "rotation writes a new 48-hex password" "1" \
  "$(printf '%s\n' "$new_pw" | grep -cE '^[0-9a-f]{48}$')"
assert_eq "the ALTER on stdin carries that password" "1" \
  "$(grep -cF "ALTER ROLE explorer_ro WITH PASSWORD '$new_pw';" "$SQL_CAPTURE")"
assert_eq "the DSN carries that password" \
  "LAKE_CATALOG_RO_DSN=postgresql://explorer_ro:$new_pw@lake-skeleton-catalog:5432/lake_catalog_skeleton" \
  "$(grep '^LAKE_CATALOG_RO_DSN=' "$ENV_FILE")"
assert_eq "no line keeps the old password" "0" "$(grep -c '0ld0ld0ld' "$ENV_FILE" || true)"
assert_eq "positive control: the shims saw openssl and the stub's cat" "1 1" \
  "$(grep -c '^openssl rand' "$ARGV_LOG") $(grep -c '^cat $' "$ARGV_LOG")"
assert_eq "no external command the rotation ran had the password in its argv" "0" \
  "$(grep -cF "$new_pw" "$ARGV_LOG" || true)"
# Security c69944: every setting that could log the ALTER, the successful
# one included, is off before it.
assert_eq "the session turns off every statement log before anything else" \
  "SET log_min_error_statement TO panic;|SET log_statement TO 'none';|SET pg_stat_statements.track_utility TO off;" \
  "$(head -n 3 "$SQL_CAPTURE" | paste -sd'|')"
alter_line="$(grep -n '^ALTER ROLE explorer_ro WITH PASSWORD' "$SQL_CAPTURE" | cut -d: -f1)"
assert_eq "and the ALTER comes after all three" "1" "$([ "${alter_line:-0}" -gt 3 ] && echo 1 || echo 0)"

# A failed ALTER must not echo the password: psql's error context quotes the
# statement. The stub fails the way psql does, quoting its input on stderr.
rc=0
err_out="$(
  catalog_psql() { local sql; sql="$(cat)"; printf 'ERROR:  boom\nLINE 1: %s\n' "$sql" >&2; return 3; }
  env_set LAKE_CATALOG_RO_PASSWORD pending
  bootstrap_catalog_role 2>&1 >/dev/null
)" || rc=$?
failed_pw="$(grep '^LAKE_CATALOG_RO_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)"
assert_rc "a failed catalog SQL is a refusal" "1" "$rc"
assert_eq "positive control: the failure's output quoted the SQL" "1" \
  "$(grep -c 'LINE 1: SET log_min_error_statement' <<<"$err_out")"
assert_eq "and the password is redacted from it" "0" "$(grep -cF "$failed_pw" <<<"$err_out" || true)"
assert_eq "where it stood, <redacted> is printed" "1" \
  "$(grep -c "PASSWORD '<redacted>'" <<<"$err_out")"

rc=0; ENV_FILE="$TMPDIR_TEST/nl.env" env_set SOME_KEY $'a\nINJECTED=1' 2>/dev/null || rc=$?
assert_rc "env_set refuses a value containing a newline" "1" "$rc"

( cd "$TMPDIR_TEST" && ENV_FILE="relative.env" env_set REL_KEY "relvalue" )
assert_eq "env_set writes a file named without a directory" \
  "REL_KEY=relvalue" "$(grep '^REL_KEY=' "$TMPDIR_TEST/relative.env")"

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

# The staging pair (#9601): both compose files must read the names the
# bootstrap writes, the main one for explorer-api and the skeleton one so that
# verify can prove the key's bounds. Each with an inert :- default, so a host
# that has not issued it still renders the whole file.
for key in LAKE_S3_STAGING_BUCKET EXPLORER_S3_STAGING_ACCESS_KEY EXPLORER_S3_STAGING_SECRET_KEY; do
  for f in docker-compose.yml docker-compose.lake-skeleton.yml; do
    if grep -q "\${$key:-" "$f"; then
      PASS=$((PASS + 1)); echo "[PASS] $f reads $key with an inert default"
    else
      FAIL=$((FAIL + 1)); echo "[FAIL] $f does not read $key with an inert :- default"
    fi
  done
done
assert_eq "the staging key name is the one the bootstrap issues" \
  "lake-skeleton-explorer-staging-wo" "$STAGING_KEY_NAME"
assert_eq "the staging bucket defaults to the name compose defaults to" \
  "lake-skeleton-staging" "$STAGING_BUCKET"

# A staging bucket that IS bronze would hand the explorer's write key bronze.
# bootstrap_garage must refuse before it makes a single Garage call (#9601,
# security review c59052). garage_cli is stubbed to record that it was reached.
GARAGE_CALLS="$TMPDIR_TEST/garage-calls"
: > "$GARAGE_CALLS"
rc=0
(
  garage_cli() { echo "$*" >> "$GARAGE_CALLS"; }
  STAGING_BUCKET="$BUCKET"
  bootstrap_garage 2>/dev/null
) || rc=$?
assert_eq "bootstrap refuses when the staging bucket equals bronze" "1" "$rc"
assert_eq "and makes no Garage call at all" "0" "$(wc -l < "$GARAGE_CALLS")"


# --- layer1_check (#4273-B1) --------------------------------------------------
# Mocked findmnt/lsblk rather than the box's real disk layout: a bash function
# shadows the PATH binary of the same name when layer1_check calls it bare, so
# this is deterministic regardless of whether the host running the suite
# happens to have a LUKS mapping anywhere.

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
LAKE_S3_STAGING_BUCKET=lake-skeleton-staging
EXPLORER_S3_STAGING_ACCESS_KEY=GKnewstaging
EXPLORER_S3_STAGING_SECRET_KEY=newstagingsecret0123
EOF
# A deploy .env from before #9601: the read-only pair and no staging keys at
# all, which check must report as missing rather than pass over.
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
assert_eq "and each staging key the deploy .env lacks" "3" "$(grep -c 'is missing from' <<<"$out")"
if grep -qE 'oldsecret|newsecret|oldpw|newpw|stagingsecret' <<<"$out"; then
  FAIL=$((FAIL + 1)); echo "[FAIL] check output contains a credential value"
else
  PASS=$((PASS + 1)); echo "[PASS] check output contains no credential value"
fi

# A standing backup from an earlier sync, as the cell had from 2026-11-11.
install -m 600 "$DEPLOY_ENV" "$ROOT/deploy-env.bak-20261111T164917Z"
explorer_env_sync > /dev/null
assert_eq "sync copies the catalog DSN under the name compose reads" \
  "LAKE_CATALOG_DSN=$NEW_DSN" "$(grep '^LAKE_CATALOG_DSN=' "$DEPLOY_ENV")"
assert_eq "sync copies the secret key" \
  "EXPLORER_S3_SECRET_KEY=newsecret0123" "$(grep '^EXPLORER_S3_SECRET_KEY=' "$DEPLOY_ENV")"
assert_eq "sync adds the staging secret key the deploy .env lacked" \
  "EXPLORER_S3_STAGING_SECRET_KEY=newstagingsecret0123" \
  "$(grep '^EXPLORER_S3_STAGING_SECRET_KEY=' "$DEPLOY_ENV")"
assert_eq "sync adds the staging bucket name" \
  "LAKE_S3_STAGING_BUCKET=lake-skeleton-staging" "$(grep '^LAKE_S3_STAGING_BUCKET=' "$DEPLOY_ENV")"
assert_eq "sync leaves other keys alone" "UNRELATED=keep-me" "$(grep '^UNRELATED=' "$DEPLOY_ENV")"
# The backup exists only while a sync is in flight (#11381, security c69938):
# after a sync whose check passes, no copy of the old served secrets is left,
# the standing one from an earlier sync included.
assert_eq "a passing sync leaves no backup, an earlier one included" \
  "0" "$(find "$ROOT" -maxdepth 1 -name 'deploy-env.bak-*' | wc -l)"
rc=0; explorer_env_check > /dev/null || rc=$?
assert_rc "check passes after sync" "0" "$rc"
assert_eq "sync leaves the deploy .env at mode 600" "600" "$(stat -c %a "$DEPLOY_ENV")"
explorer_env_sync > /dev/null
assert_eq "a second sync leaves no backup either" \
  "0" "$(find "$ROOT" -maxdepth 1 -name 'deploy-env.bak-*' | wc -l)"

# A sync that fails part way keeps the backup, the only way back. env_set
# cannot create its temp copy in a read-only directory.
RO_DIR="$TMPDIR_TEST/ro-deploy"
mkdir -p "$RO_DIR"
printf 'UNRELATED=keep-me\nEXPLORER_S3_ACCESS_KEY=GKoldkey\n' > "$RO_DIR/deploy.env"
chmod 600 "$RO_DIR/deploy.env"
chmod 555 "$RO_DIR"
rc=0; DEPLOY_ENV_FILE="$RO_DIR/deploy.env" explorer_env_sync > /dev/null 2>&1 || rc=$?
chmod 755 "$RO_DIR"
assert_rc "sync reports a write that failed" "1" "$rc"
assert_eq "and keeps the backup, mode 600" \
  "600" "$(stat -c %a "$ROOT"/deploy-env.bak-* 2>/dev/null)"
assert_eq "which holds the previous credentials" \
  "EXPLORER_S3_ACCESS_KEY=GKoldkey" "$(grep -h '^EXPLORER_S3_ACCESS_KEY=' "$ROOT"/deploy-env.bak-* 2>/dev/null)"
rm -f "$ROOT"/deploy-env.bak-*

# env_set's value is a sed replacement: | ends it, & and \ are special.
rc=0; ENV_FILE="$TMPDIR_TEST/sed.env" env_set SOME_KEY 'a&b' 2>/dev/null || rc=$?
assert_rc "env_set refuses a value containing &" "1" "$rc"
sed -i '/^EXPLORER_S3_ACCESS_KEY=/d' "$SKEL_ENV"
printf 'EXPLORER_S3_ACCESS_KEY=GK|bad\n' >> "$SKEL_ENV"
before="$(cat "$DEPLOY_ENV")"
rc=0; explorer_env_sync > /dev/null 2>&1 || rc=$?
assert_rc "sync refuses a skeleton value containing |" "1" "$rc"
assert_eq "and writes none of the mapped keys" "$before" "$(cat "$DEPLOY_ENV")"
sed -i '/^EXPLORER_S3_ACCESS_KEY=/d' "$SKEL_ENV"
printf 'EXPLORER_S3_ACCESS_KEY=GKnewkey\n' >> "$SKEL_ENV"

# If the skeleton is only half-issued (bootstrap interrupted), sync must not
# overwrite a working deploy .env with a mix of new and placeholder values.
sed -i 's|^EXPLORER_S3_SECRET_KEY=.*|EXPLORER_S3_SECRET_KEY=pending|' "$SKEL_ENV"
before="$(cat "$DEPLOY_ENV")"
rc=0; explorer_env_sync > /dev/null 2>&1 || rc=$?
assert_rc "sync refuses while a skeleton credential is still pending" "1" "$rc"
assert_eq "and writes nothing" "$before" "$(cat "$DEPLOY_ENV")"

# A host whose skeleton predates #9601 has the read-only pair issued and the
# staging pair still 'pending' until its next 'up'. Sync must not half-apply.
sed -i 's|^EXPLORER_S3_SECRET_KEY=.*|EXPLORER_S3_SECRET_KEY=newsecret0123|' "$SKEL_ENV"
sed -i 's|^EXPLORER_S3_STAGING_ACCESS_KEY=.*|EXPLORER_S3_STAGING_ACCESS_KEY=pending|' "$SKEL_ENV"
before="$(cat "$DEPLOY_ENV")"
rc=0; explorer_env_sync > /dev/null 2>&1 || rc=$?
assert_rc "sync refuses while the staging key is still pending" "1" "$rc"
assert_eq "and writes nothing, the read-only pair included" "$before" "$(cat "$DEPLOY_ENV")"

DEPLOY_ENV_FILE="$TMPDIR_TEST/absent-deploy.env"
rc=0; explorer_env_sync > /dev/null 2>&1 || rc=$?
assert_rc "sync refuses when the deploy .env does not exist" "1" "$rc"

# --- stage_real_kek (#10354): a real KEK never reaches compose's env --------
# substitution — it goes to a 0600 tmpfs file instead, and LAKE_KEK_HEX is
# unset in this shell afterward so `compose`'s `${LAKE_KEK_HEX:-}` reads
# empty for the call that follows.

unset LAKE_KEK_HEX LAKE_KEK_FILE_HOST
_kek_file=""
stage_real_kek
assert_eq "no-op when LAKE_KEK_HEX is unset: no file staged" "" "$_kek_file"
assert_eq "no-op when LAKE_KEK_HEX is unset: no host path exported" "" "${LAKE_KEK_FILE_HOST:-}"

# Real tmpfs, not $TMPDIR_TEST (mktemp's backing filesystem on this host is
# ext2/ext3, not tmpfs) — stage_real_kek now refuses a non-tmpfs runtime dir
# (#10492), and /run/user/<uid> on a real deploy always is tmpfs, so the test
# has to mirror that rather than the arbitrary disk mktemp -d happens to use.
TMPFS_RUNTIME_DIR="$(mktemp -d -p /dev/shm lake-skeleton-unit-runtime.XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST" "$TMPFS_RUNTIME_DIR"' EXIT
export XDG_RUNTIME_DIR="$TMPFS_RUNTIME_DIR"
export LAKE_KEK_HEX="feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"
_kek_file=""
stage_real_kek
if [ -n "$_kek_file" ] && [ -f "$_kek_file" ]; then
  PASS=$((PASS + 1)); echo "[PASS] a real KEK is staged to a file"
else
  FAIL=$((FAIL + 1)); echo "[FAIL] a real KEK is staged to a file"
fi
assert_eq "the staged file is 0600" "600" "$(stat -c '%a' "$_kek_file" 2>/dev/null)"
assert_eq "the staged file holds the real hex" \
  "feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface" "$(cat "$_kek_file")"
assert_eq "LAKE_KEK_FILE_HOST is exported to the staged path" "$_kek_file" "${LAKE_KEK_FILE_HOST:-}"
assert_eq "LAKE_KEK_HEX is unset after staging, so compose never sees it" "" "${LAKE_KEK_HEX:-}"

staged_path="$_kek_file"
_cleanup_kek_file
if [ ! -e "$staged_path" ]; then
  PASS=$((PASS + 1)); echo "[PASS] the staged file is deleted by the cleanup trap"
else
  FAIL=$((FAIL + 1)); echo "[FAIL] the staged file is deleted by the cleanup trap"
fi
unset LAKE_KEK_FILE_HOST

# --- stage_real_kek refuses a non-tmpfs runtime dir (#10492, security review
#     c64726 on #8813): a misconfigured XDG_RUNTIME_DIR must not let a real
#     KEK land on disk. Run in a subshell: the refusal is a hard `exit 1`,
#     which would otherwise kill this whole test script.
disk_runtime_dir="$TMPDIR_TEST/not-tmpfs-runtime"
mkdir -p "$disk_runtime_dir"
rc=0
( export XDG_RUNTIME_DIR="$disk_runtime_dir"
  export LAKE_KEK_HEX="feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"
  stage_real_kek
) >/dev/null 2>&1 || rc=$?
assert_rc "stage_real_kek refuses a non-tmpfs \$XDG_RUNTIME_DIR" "1" "$rc"
if [ -z "$(find "$disk_runtime_dir" -mindepth 1 2>/dev/null)" ]; then
  PASS=$((PASS + 1)); echo "[PASS] the refusal writes no file to the non-tmpfs dir"
else
  FAIL=$((FAIL + 1)); echo "[FAIL] the refusal writes no file to the non-tmpfs dir"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "FAILED: $FAIL failed, $PASS passed"
  exit 1
fi
echo "$PASS passed, 0 failed"
