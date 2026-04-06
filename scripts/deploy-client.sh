#!/usr/bin/env bash
set -euo pipefail

# Blue-green client deploy. Swaps which slot gets port 80 via
# docker-compose.override.yml, then recreates containers.
#
# Usage:
#   ./scripts/deploy-client.sh          # Pull latest + swap
#   ./scripts/deploy-client.sh status   # Show active slot
#   ./scripts/deploy-client.sh swap     # Swap without pulling (rollback)

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OVERRIDE="docker-compose.override.yml"

# Determine active slot from override file (default: blue)
if grep -q "client-green" "$OVERRIDE" 2>/dev/null; then
  ACTIVE=green STANDBY=blue
else
  ACTIVE=blue STANDBY=green
fi

write_override() {
  cat > "$OVERRIDE" <<EOF
services:
  client-$1:
    ports:
      - "80:80"
      - "8999:80"
EOF
}

case "${1:-deploy}" in
  status)
    echo "Active: client-$ACTIVE"
    docker compose ps client-blue client-green 2>/dev/null
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
    write_override "$STANDBY"
    docker compose up -d
    docker compose stop "client-$ACTIVE"
    echo "Done. Active: client-$STANDBY"
    ;;
  swap)
    echo "Swapping: client-$ACTIVE -> client-$STANDBY (no pull)"
    write_override "$STANDBY"
    docker compose up -d
    docker compose stop "client-$ACTIVE"
    echo "Done. Active: client-$STANDBY"
    ;;
  *)
    echo "Usage: $0 [deploy|swap|status]"
    exit 1
    ;;
esac
