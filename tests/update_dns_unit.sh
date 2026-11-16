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

# ROOT_RECORD_ID is optional once the apex is on the tunnel (#10829-A3).
unset ROOT_RECORD_ID
assert_eq "0" "$(rc_of require_vars)" "require_vars passes with ROOT_RECORD_ID blank"
ROOT_RECORD_ID=root-abc

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
assert_contains "$LOG_TEXT" "HOME_RECORD_ID" "require_vars names the missing HOME_RECORD_ID"
assert_eq "0" "$(grep -c 'ROOT_RECORD_ID' "$DDNS_LOG_FILE" || true)" \
  "require_vars does not demand ROOT_RECORD_ID (optional since #10829-A3)"
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

# --- record_field -----------------------------------------------------------

A_REC='{"result":{"id":"r1","type":"A","name":"the-aspirant.com","content":"203.0.113.7","proxied":true},"success":true,"errors":[]}'
CNAME_REC='{"result":{"id":"r1","type":"CNAME","name":"the-aspirant.com","content":"abc.cfargotunnel.com","proxied":true},"success":true,"errors":[]}'
assert_eq "A" "$(record_field "$A_REC" type)" "record_field reads an A record's type"
assert_eq "203.0.113.7" "$(record_field "$A_REC" content)" "record_field reads an A record's content"
assert_eq "CNAME" "$(record_field "$CNAME_REC" type)" "record_field reads a CNAME's type"

# --- apex_action (#10829-A3) ------------------------------------------------

IP=203.0.113.9
assert_eq "skip"   "$(apex_action ""   1 A     203.0.113.7 "$IP")" "apex: blank ROOT_RECORD_ID is not managed"
assert_eq "error"  "$(apex_action r1   0 ""    ""          "$IP")" "apex: an unreadable configured record is an error"
assert_eq "noop"   "$(apex_action r1   1 A     "$IP"       "$IP")" "apex: a current A record is left alone"
assert_eq "update" "$(apex_action r1   1 A     203.0.113.7 "$IP")" "apex: a stale A record is updated"
# The one that matters: the tunnel's CNAME never mismatches into an A-record PUT.
assert_eq "skip"   "$(apex_action r1   1 CNAME abc.cfargotunnel.com "$IP")" \
  "apex: a CNAME (the tunnel) is never PUT back as an A record"

# --- home_action ------------------------------------------------------------

assert_eq "error"  "$(home_action 0 ""          "$IP")" "home: an unreadable record is an error"
assert_eq "noop"   "$(home_action 1 "$IP"       "$IP")" "home: a current record is left alone"
# Previously only reached when the apex was stale: home is now judged on its own.
assert_eq "update" "$(home_action 1 203.0.113.7 "$IP")" "home: a stale record is updated even if the apex is current"

# --- no credential material in the repo -------------------------------------

# The predecessor's failure mode was a live token committed in a script body.
assert_eq "" "$(grep -oE '^(CF_TOKEN|ZONE_ID|ROOT_RECORD_ID|HOME_RECORD_ID)=.+' \
  ./scripts/update-dns.sh ./scripts/ddns.env.template || true)" \
  "no credential is assigned a value in the script or template"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
