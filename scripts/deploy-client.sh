#!/usr/bin/env bash
set -euo pipefail

# Blue-green client deploy. Swaps which slot gets port 80 via
# docker-compose.override.yml, then recreates containers.
#
# Usage:
#   ./scripts/deploy-client.sh                # Pull latest + swap
#   ./scripts/deploy-client.sh status         # Show active slot
#   ./scripts/deploy-client.sh swap [slot]    # Swap without pulling (rollback).
#                                             # With an explicit slot (blue|green)
#                                             # the verb is idempotent: it makes
#                                             # THAT slot active and no-ops if it
#                                             # already is — safe to retry.
#
# All compose invocations target the two client services explicitly:
# an untargeted `docker compose up -d` pulls every project-wide missing
# image first, so a newly merged sub-stack whose images have not landed
# yet (or a dead registry link) would block client deploys entirely.

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OVERRIDE="docker-compose.override.yml"
CLIENT_SERVICES=(client-blue client-green)

# Pure helpers (unit-tested via ASPIRANT_DEPLOY_CLIENT_LIB=1).

read_active_slot() {  # read_active_slot <override-file> -> blue|green
  local override="$1"
  if grep -q "client-green" "$override" 2>/dev/null; then
    echo green
  else
    echo blue
  fi
}

other_slot() {  # other_slot <slot> -> the opposite slot
  [[ "$1" == "green" ]] && echo blue || echo green
}

resolve_swap_target() {  # resolve_swap_target <active> [requested] -> slot | "noop"
  local active="$1" requested="${2:-}"
  if [[ -z "$requested" ]]; then
    other_slot "$active"
    return 0
  fi
  case "$requested" in
    blue|green) ;;
    *) echo "invalid" ; return 0 ;;
  esac
  if [[ "$requested" == "$active" ]]; then
    echo "noop"
  else
    echo "$requested"
  fi
}

write_override() {  # write_override <slot> [override-file]
  cat > "${2:-$OVERRIDE}" <<EOF
services:
  client-$1:
    ports:
      - "80:80"
      - "8999:80"
EOF
}

# Test-mode escape hatch: source with ASPIRANT_DEPLOY_CLIENT_LIB=1 to expose
# the pure helpers without touching docker or the override file.
if [[ "${ASPIRANT_DEPLOY_CLIENT_LIB:-0}" -eq 1 ]]; then
  return 0
fi

ACTIVE="$(read_active_slot "$OVERRIDE")"
STANDBY="$(other_slot "$ACTIVE")"

apply_slot() {  # apply_slot <new-active> <new-standby>
  write_override "$1"
  docker compose up -d "${CLIENT_SERVICES[@]}"
  docker compose stop "client-$2"
}

case "${1:-deploy}" in
  status)
    echo "Active: client-$ACTIVE"
    docker compose ps "${CLIENT_SERVICES[@]}" 2>/dev/null
    ;;
  deploy)
    echo "Deploying: client-$ACTIVE -> client-$STANDBY"
    docker compose pull "client-$STANDBY"
    docker compose up -d --force-recreate "client-$STANDBY"
    echo "Health-checking client-$STANDBY..."
    OK=false
    for i in 1 2 3 4 5; do
      if docker compose exec -T "client-$STANDBY" wget -qO /dev/null --timeout=5 http://127.0.0.1:80/ 2>/dev/null; then
        OK=true; break
      fi
      sleep 2
    done
    if [ "$OK" = false ]; then
      echo "FAIL — stopping client-$STANDBY, client-$ACTIVE still serving"
      docker compose stop "client-$STANDBY"
      exit 1
    fi
    apply_slot "$STANDBY" "$ACTIVE"
    echo "Done. Active: client-$STANDBY"
    # Validate the now-live cross-service journey (#5921). The per-slot health
    # check above only proves the client serves HTML; it cannot see a broken
    # /decide route or a 502 from the server — the defects that shipped silently.
    # A failure here does NOT auto-rollback (the cause may be the server or the
    # commander, which a client rollback would not fix); it warns loudly and logs
    # a fleet signal so someone looks. Opt out with SMOKE_SKIP=1.
    # (cwd is the deploy root — see the `cd` at the top of this script.)
    if [ "${SMOKE_SKIP:-0}" != "1" ] && [ -x "scripts/post-deploy-smoke.sh" ]; then
      echo "Running post-deploy valuation smoke check..."
      ./scripts/post-deploy-smoke.sh || echo "WARNING: post-deploy smoke check reported a failure (see above); traffic stays on client-$STANDBY — investigate."
    fi
    ;;
  swap)
    TARGET="$(resolve_swap_target "$ACTIVE" "${2:-}")"
    case "$TARGET" in
      noop)
        echo "client-$ACTIVE already active — nothing to do"
        ;;
      invalid)
        echo "Unknown slot '${2:-}' (expected blue|green)"
        exit 1
        ;;
      *)
        echo "Swapping: client-$ACTIVE -> client-$TARGET (no pull)"
        apply_slot "$TARGET" "$ACTIVE"
        echo "Done. Active: client-$TARGET"
        ;;
    esac
    ;;
  *)
    echo "Usage: $0 [deploy|swap [blue|green]|status]"
    exit 1
    ;;
esac
