#!/usr/bin/env bash
#
# system3_freeze.sh — open and close system_3's planned-maintenance freeze around
# a LUKS ceremony (#7342, epic #7149).
#
# Sourced by preflight.sh, postcheck.sh and ../luks-unlock/unlock.sh. Defines
# functions only; sourcing it has no side effects.
#
# The freeze tells the fleet the window is planned: verifies wait instead of
# running into the outage, automated spawns pause, and anomalies raised during it
# are tagged planned_maintenance (never suppressed). It is system_3's
# `s3 orch maintenance open|status|close` (#7338), a bounded flag that lapses by
# itself, so a ceremony abandoned mid-way cannot pause the fleet for good.
#
# Two rules:
#   * The flag lives in the invoking user's ~/.system3. These scripts run under
#     sudo, and as root the verb would write /root/.system3, which the fleet
#     never reads, or leave a root-owned flag the fleet cannot close. So when run
#     as root the verb runs as $SUDO_USER (falling back to the owner of $S3_BIN).
#   * The freeze is a convenience, not a gate. A missing s3 or a failed verb
#     prints a [WARN] and returns 0; it never aborts the ceremony.
#
# Overrides (env): S3_BIN, LUKS_FREEZE_ACTOR_ID (default 207, the operator
# handle 'aspirant': the operator runs the ceremony).

: "${S3_BIN:=/home/aspirant/system_3/.venv/bin/s3}"
: "${LUKS_FREEZE_ACTOR_ID:=207}"

_system3_freeze() {
  if [[ ! -x "$S3_BIN" ]]; then
    printf '  [WARN] system_3 freeze skipped: %s not found (the fleet is not told this window is planned)\n' "$S3_BIN"
    return 0
  fi
  local -a runas=()
  if [[ $EUID -eq 0 ]]; then
    local owner="${SUDO_USER:-}"
    [[ -n "$owner" && "$owner" != root ]] || owner="$(stat -c %U "$S3_BIN")"
    [[ "$owner" != root ]] && runas=(sudo -u "$owner" -H --)
  fi
  if "${runas[@]}" "$S3_BIN" orch maintenance "$@"; then
    return 0
  fi
  printf '  [WARN] system_3 freeze command failed (orch maintenance %s); the ceremony continues, the freeze is a convenience, not a gate\n' "$1"
  return 0
}

# freeze_open <reason> <minutes>: open the freeze, or extend the one in force.
freeze_open()   { _system3_freeze open --reason "$1" --minutes "$2" --actor-id "$LUKS_FREEZE_ACTOR_ID"; }
freeze_close()  { _system3_freeze close --actor-id "$LUKS_FREEZE_ACTOR_ID"; }
freeze_status() { _system3_freeze status; }
