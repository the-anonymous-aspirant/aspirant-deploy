#!/usr/bin/env bash
set -euo pipefail

# update-dns.sh — dynamic DNS updater for Cloudflare. Keeps two A records
# pointed at the cell's current public IP:
#   the-aspirant.com       proxied, TTL auto   — web traffic via the CDN
#   home.the-aspirant.com  direct,  TTL 300    — the SSH entry point
#
# Intended to run from the `aspirant` user's crontab:
#   */5 * * * * /home/aspirant/aspirant-deploy/scripts/update-dns.sh
#   @reboot     /home/aspirant/aspirant-deploy/scripts/update-dns.sh
#
# Credentials are NOT in this file. They are read from an env file, default
# ~/.config/aspirant/ddns.env, which must be owned by the user running the
# cron and mode 0600. See scripts/ddns.env.template and docs/OPERATIONS.md
# §Cloudflare DDNS credential. Overridable for testing via DDNS_ENV_FILE.
#
# The predecessor of this script hardcoded a zone-wide Cloudflare token at
# line 5 of a mode-775 file in the home directory, and captured the response
# of the home-record update without ever checking it — so a failed update of
# the SSH entry point logged as a success. Both are fixed here; see
# system_3 task #2393.
#
# Exit codes: 0 no-op or both records updated; 1 preflight or update failure.

DDNS_ENV_FILE="${DDNS_ENV_FILE:-$HOME/.config/aspirant/ddns.env}"
DDNS_LOG_FILE="${DDNS_LOG_FILE:-$HOME/ddns.log}"
IPIFY_URL="${DDNS_IPIFY_URL:-https://api.ipify.org}"
CF_API="${DDNS_CF_API:-https://api.cloudflare.com/client/v4}"

REQUIRED_VARS=(CF_TOKEN ZONE_ID ROOT_RECORD_ID HOME_RECORD_ID)

log_line() {
  printf '%s - %s\n' "$(date)" "$1" >> "$DDNS_LOG_FILE"
}

# Read the env file into the environment. Fails closed: an absent or
# unreadable file is a hard error, never a fallback to an empty token that
# would send unauthenticated requests to Cloudflare in a 5-minute loop.
load_env_file() {
  local path="$1"
  if [[ ! -r "$path" ]]; then
    log_line "ERROR: credential file not readable: $path"
    return 1
  fi
  # shellcheck disable=SC1090
  set -a; source "$path"; set +a
}

# Every credential the update needs must be non-empty after sourcing.
# Reported as one line naming all missing vars, so a half-filled env file
# takes one cron tick to diagnose rather than four.
require_vars() {
  local missing=()
  local name
  for name in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!name:-}" ]]; then
      missing+=("$name")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    log_line "ERROR: credential file missing: ${missing[*]}"
    return 1
  fi
}

# Cloudflare returns 200 with "success":false on a rejected edit, so the HTTP
# status is not the signal — the body is.
cf_success() {
  grep -q '"success":true' <<< "$1"
}

cf_get_record_ip() {
  curl -s -X GET "$CF_API/zones/$ZONE_ID/dns_records/$1" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    | grep -o '"content":"[^"]*' | cut -d'"' -f4
}

cf_put_record() {
  local record_id="$1" name="$2" ip="$3" ttl="$4" proxied="$5"
  curl -s -X PUT "$CF_API/zones/$ZONE_ID/dns_records/$record_id" \
    -H "Authorization: Bearer $CF_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$name\",\"content\":\"$ip\",\"ttl\":$ttl,\"proxied\":$proxied}"
}

# Library mode: tests source this file for the pure helpers above without
# running the update. Mirrors ASPIRANT_DEPLOY_CLIENT_LIB in deploy-client.sh.
if [[ -n "${ASPIRANT_UPDATE_DNS_LIB:-}" ]]; then
  return 0
fi

load_env_file "$DDNS_ENV_FILE" || exit 1
require_vars || exit 1

CURRENT_IP="$(curl -s "$IPIFY_URL")"
if [[ -z "$CURRENT_IP" ]]; then
  log_line "ERROR: Failed to get public IP"
  exit 1
fi

CF_IP="$(cf_get_record_ip "$ROOT_RECORD_ID")"

if [[ "$CURRENT_IP" == "$CF_IP" ]]; then
  exit 0
fi

RESPONSE_ROOT="$(cf_put_record "$ROOT_RECORD_ID" "the-aspirant.com" "$CURRENT_IP" 1 true)"
RESPONSE_HOME="$(cf_put_record "$HOME_RECORD_ID" "home.the-aspirant.com" "$CURRENT_IP" 300 false)"

FAILED=0

if cf_success "$RESPONSE_ROOT"; then
  log_line "Updated the-aspirant.com: $CF_IP -> $CURRENT_IP"
else
  log_line "ERROR: Failed to update the-aspirant.com: $RESPONSE_ROOT"
  FAILED=1
fi

# Checked separately and logged distinctly: this is the record SSH resolves
# through. If it fails while the root record succeeds, web traffic follows the
# new IP and the box becomes unreachable — the one failure that must not be
# summarised away under a single "Updated DNS" line.
if cf_success "$RESPONSE_HOME"; then
  log_line "Updated home.the-aspirant.com: $CF_IP -> $CURRENT_IP"
else
  log_line "ERROR: Failed to update home.the-aspirant.com (SSH entry point): $RESPONSE_HOME"
  FAILED=1
fi

exit "$FAILED"
