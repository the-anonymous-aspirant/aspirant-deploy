#!/usr/bin/env bash
set -euo pipefail

# Unit tests for scripts/update-dns.sh's pure logic — load_env_file(),
# require_vars(), and cf_success(). No network and no Cloudflare credential
# required; the script is sourced in library mode so it returns before the
# update path runs.
#
# Usage: ./tests/update_dns_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export ASPIRANT_UPDATE_DNS_LIB=1
export DDNS_LOG_FILE="$TMPDIR_TEST/ddns.log"

# shellcheck disable=SC1091
source ./scripts/update-dns.sh

PASS=0
FAIL=0

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %s — expected %q got %q\n" "$label" "$expected" "$actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %s — %q not found in %q\n" "$label" "$needle" "$haystack"
  fi
}

rc_of() {
  local rc=0
  "$@" || rc=$?
  printf '%s' "$rc"
}

clear_creds() {
  unset CF_TOKEN ZONE_ID ROOT_RECORD_ID HOME_RECORD_ID
}

# --- load_env_file ----------------------------------------------------------

# Absent file fails closed rather than proceeding with an empty token.
assert_eq "1" "$(rc_of load_env_file "$TMPDIR_TEST/nonexistent.env")" \
  "load_env_file rejects a missing credential file"
assert_contains "$(cat "$DDNS_LOG_FILE")" "credential file not readable" \
  "load_env_file logs the missing credential file"

# Unreadable file (present but mode 000) is the same refusal, not a pass.
UNREADABLE="$TMPDIR_TEST/unreadable.env"
printf 'CF_TOKEN=t\n' > "$UNREADABLE"
chmod 000 "$UNREADABLE"
if [[ "$(id -u)" -eq 0 ]]; then
  printf "  SKIP  load_env_file rejects an unreadable file (running as root)\n"
else
  assert_eq "1" "$(rc_of load_env_file "$UNREADABLE")" \
    "load_env_file rejects an unreadable credential file"
fi
chmod 600 "$UNREADABLE"

# A well-formed file populates every required variable.
GOOD="$TMPDIR_TEST/good.env"
cat > "$GOOD" <<'EOF'
CF_TOKEN=tok-abc
ZONE_ID=zone-abc
ROOT_RECORD_ID=root-abc
HOME_RECORD_ID=home-abc
EOF
clear_creds
assert_eq "0" "$(rc_of load_env_file "$GOOD")" "load_env_file accepts a well-formed file"
load_env_file "$GOOD"
assert_eq "tok-abc" "${CF_TOKEN}" "load_env_file exports CF_TOKEN"
assert_eq "zone-abc" "${ZONE_ID}" "load_env_file exports ZONE_ID"
assert_eq "root-abc" "${ROOT_RECORD_ID}" "load_env_file exports ROOT_RECORD_ID"
assert_eq "home-abc" "${HOME_RECORD_ID}" "load_env_file exports HOME_RECORD_ID"

# --- require_vars -----------------------------------------------------------

assert_eq "0" "$(rc_of require_vars)" "require_vars passes with all four set"

# The shipped template has every value blank — installing it without editing
# must be caught before any request goes out.
clear_creds
load_env_file ./scripts/ddns.env.template
assert_eq "1" "$(rc_of require_vars)" "require_vars rejects the unedited template"

# A half-filled file names every missing variable in one line.
clear_creds
: > "$DDNS_LOG_FILE"
CF_TOKEN=tok-abc
ZONE_ID=zone-abc
require_vars || true
LOG_TEXT="$(cat "$DDNS_LOG_FILE")"
assert_contains "$LOG_TEXT" "ROOT_RECORD_ID" "require_vars names the missing ROOT_RECORD_ID"
assert_contains "$LOG_TEXT" "HOME_RECORD_ID" "require_vars names the missing HOME_RECORD_ID"
assert_eq "1" "$(grep -c 'ERROR: credential file missing' "$DDNS_LOG_FILE")" \
  "require_vars reports all missing vars on one line"

# --- cf_success -------------------------------------------------------------

assert_eq "0" "$(rc_of cf_success '{"result":{},"success":true,"errors":[]}')" \
  "cf_success accepts a success body"
assert_eq "1" "$(rc_of cf_success '{"result":null,"success":false,"errors":[{"code":10000}]}')" \
  "cf_success rejects a failure body"
assert_eq "1" "$(rc_of cf_success '{"success": true}')" \
  "cf_success rejects a body whose success key is not the compact form"
assert_eq "1" "$(rc_of cf_success '')" "cf_success rejects an empty body"

# --- no credential material in the repo -------------------------------------

# The predecessor's failure mode was a live token committed in a script body.
assert_eq "" "$(grep -oE '^(CF_TOKEN|ZONE_ID|ROOT_RECORD_ID|HOME_RECORD_ID)=.+' \
  ./scripts/update-dns.sh ./scripts/ddns.env.template || true)" \
  "no credential is assigned a value in the script or template"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
