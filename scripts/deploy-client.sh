#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Blue-Green Deploy — Aspirant Client
#
# Deploys a new client image with zero downtime by swapping between two
# container slots (blue/green) behind an nginx gateway.
#
# Usage:
#   ./scripts/deploy-client.sh          # Pull latest and swap
#   ./scripts/deploy-client.sh status   # Show current active slot
#   ./scripts/deploy-client.sh swap     # Swap without pulling (e.g. rollback)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$DEPLOY_DIR/nginx/state"
UPSTREAM_CONF="$STATE_DIR/active-upstream.conf"
COMPOSE="docker compose -f $DEPLOY_DIR/docker-compose.yml"
HEALTH_RETRIES=15
HEALTH_SLEEP=2
HEALTH_TIMEOUT=5

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf "${BOLD}[deploy]${RESET} %s\n" "$1"; }
ok()   { printf "${GREEN}[deploy]${RESET} %s\n" "$1"; }
warn() { printf "${YELLOW}[deploy]${RESET} %s\n" "$1"; }
err()  { printf "${RED}[deploy]${RESET} %s\n" "$1" >&2; }

get_active_slot() {
    if grep -q "client-green" "$UPSTREAM_CONF" 2>/dev/null; then
        echo "green"
    else
        echo "blue"
    fi
}

get_inactive_slot() {
    if [[ "$(get_active_slot)" == "blue" ]]; then
        echo "green"
    else
        echo "blue"
    fi
}

write_upstream() {
    local slot="$1"
    cat > "$UPSTREAM_CONF" <<EOF
upstream active_client {
    server client-${slot}:80;
}
EOF
}

health_check() {
    local container="$1"

    # Use wget (available in alpine/busybox) to hit nginx inside the container
    for i in $(seq 1 "$HEALTH_RETRIES"); do
        if $COMPOSE exec -T "$container" wget -q --spider --timeout="$HEALTH_TIMEOUT" http://localhost:80/ 2>/dev/null; then
            return 0
        fi
        if [[ "$i" -lt "$HEALTH_RETRIES" ]]; then
            sleep "$HEALTH_SLEEP"
        fi
    done
    return 1
}

reload_gateway() {
    $COMPOSE exec -T gateway nginx -s reload
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
cmd_status() {
    local active
    active="$(get_active_slot)"
    log "Active slot: ${active}"

    # Show container status
    for slot in blue green; do
        local name="client-${slot}"
        local status
        status=$($COMPOSE ps --format '{{.State}}' "$name" 2>/dev/null || echo "not running")
        local marker=""
        if [[ "$slot" == "$active" ]]; then
            marker=" (active)"
        fi
        printf "  %-14s %s%s\n" "$name" "$status" "$marker"
    done
}

cmd_swap() {
    local active inactive
    active="$(get_active_slot)"
    inactive="$(get_inactive_slot)"

    log "Swapping: ${active} -> ${inactive}"

    # Ensure inactive slot is running
    local inactive_state
    inactive_state=$($COMPOSE ps --format '{{.State}}' "client-${inactive}" 2>/dev/null || echo "")
    if [[ "$inactive_state" != "running" ]]; then
        log "Starting client-${inactive}..."
        $COMPOSE up -d "client-${inactive}"
    fi

    # Health check the inactive slot
    log "Health-checking client-${inactive}..."
    if ! health_check "client-${inactive}"; then
        err "client-${inactive} failed health check — aborting swap"
        exit 1
    fi
    ok "client-${inactive} is healthy"

    # Switch upstream
    write_upstream "$inactive"
    reload_gateway
    ok "Gateway switched to client-${inactive}"

    # Stop old slot
    log "Stopping client-${active}..."
    $COMPOSE stop "client-${active}"
    ok "client-${active} stopped"

    ok "Deploy complete. Active slot: ${inactive}"
}

cmd_deploy() {
    local active inactive
    active="$(get_active_slot)"
    inactive="$(get_inactive_slot)"

    log "Deploying new client image (${active} -> ${inactive})"

    # Pull latest image
    log "Pulling latest client image..."
    $COMPOSE pull "client-${inactive}"

    # Start/recreate inactive slot with new image
    log "Starting client-${inactive} with new image..."
    $COMPOSE up -d --force-recreate "client-${inactive}"

    # Health check
    log "Health-checking client-${inactive}..."
    if ! health_check "client-${inactive}"; then
        err "client-${inactive} failed health check — rolling back"
        $COMPOSE stop "client-${inactive}"
        err "Deploy aborted. client-${active} still serving traffic."
        exit 1
    fi
    ok "client-${inactive} is healthy"

    # Switch upstream
    write_upstream "$inactive"
    reload_gateway
    ok "Gateway switched to client-${inactive}"

    # Stop old slot
    log "Stopping client-${active}..."
    $COMPOSE stop "client-${active}"
    ok "client-${active} stopped"

    ok "Deploy complete. Active slot: ${inactive}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-deploy}" in
    status) cmd_status ;;
    swap)   cmd_swap ;;
    deploy) cmd_deploy ;;
    *)
        echo "Usage: $0 [deploy|swap|status]"
        echo "  deploy  Pull latest image and swap (default)"
        echo "  swap    Swap slots without pulling (rollback)"
        echo "  status  Show current slot status"
        exit 1
        ;;
esac
