#!/usr/bin/env bash
set -euo pipefail

# Unit tests for scripts/deploy-client.sh's pure logic — read_active_slot(),
# other_slot(), resolve_swap_target(), and write_override(). No docker required.
#
# Usage: ./tests/deploy_client_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export ASPIRANT_DEPLOY_CLIENT_LIB=1

# Source the script in library mode (returns before touching docker).
# shellcheck disable=SC1091
source ./scripts/deploy-client.sh

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

# read_active_slot — green in override → green
OV="$TMPDIR_TEST/override.yml"
printf 'services:\n  client-green:\n    ports:\n      - "80:80"\n' > "$OV"
assert_eq "green" "$(read_active_slot "$OV")" "read_active_slot sees green override"

# read_active_slot — blue in override → blue
printf 'services:\n  client-blue:\n    ports:\n      - "80:80"\n' > "$OV"
assert_eq "blue" "$(read_active_slot "$OV")" "read_active_slot sees blue override"

# read_active_slot — missing override file defaults to blue
assert_eq "blue" "$(read_active_slot "$TMPDIR_TEST/nonexistent.yml")" "read_active_slot defaults to blue"

# other_slot
assert_eq "green" "$(other_slot blue)" "other_slot blue -> green"
assert_eq "blue" "$(other_slot green)" "other_slot green -> blue"

# resolve_swap_target — no argument toggles
assert_eq "green" "$(resolve_swap_target blue)" "swap with no arg toggles blue -> green"
assert_eq "blue" "$(resolve_swap_target green)" "swap with no arg toggles green -> blue"

# resolve_swap_target — explicit slot is idempotent (noop when already active)
assert_eq "noop" "$(resolve_swap_target green green)" "swap green while green active -> noop"
assert_eq "noop" "$(resolve_swap_target blue blue)" "swap blue while blue active -> noop"
assert_eq "green" "$(resolve_swap_target blue green)" "swap green while blue active -> green"
assert_eq "blue" "$(resolve_swap_target green blue)" "swap blue while green active -> blue"

# resolve_swap_target — invalid slot name rejected
assert_eq "invalid" "$(resolve_swap_target blue purple)" "swap rejects unknown slot"

# write_override — writes exactly one client service with both port maps
write_override green "$OV"
assert_eq "1" "$(grep -c "client-green" "$OV")" "write_override names the requested slot"
assert_eq "0" "$(grep -c "client-blue" "$OV" || true)" "write_override omits the other slot"
assert_eq "1" "$(grep -c '"80:80"' "$OV")" "write_override maps port 80"
assert_eq "1" "$(grep -c '"8999:80"' "$OV")" "write_override maps port 8999"

echo
echo "deploy_client_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
