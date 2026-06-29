#!/usr/bin/env bash
set -euo pipefail

# auto-pull.sh — poll aspirant-* :latest images, recreate containers on
# SHA drift, with health-check + rollback and a known-bad SHA cache that
# stops the loop from re-deploying an image we already saw fail.
#
# Intended to run from cron every ~5 minutes:
#   */5 * * * * /home/aspirant/aspirant-deploy/scripts/auto-pull.sh >> /var/log/aspirant-auto-pull/cron.log 2>&1
#
# Usage:
#   ./scripts/auto-pull.sh                # poll + act
#   ./scripts/auto-pull.sh --dry-run      # decide but never call docker compose pull/up
#   ./scripts/auto-pull.sh --service NAME # only consider one compose service
#   ./scripts/auto-pull.sh --once         # exit 0 after one pass (default; explicit flag for clarity)
#
# Outputs:
#   /var/log/aspirant-auto-pull/decisions.jsonl   one JSON line per (service, run, decision)
#   /var/lib/aspirant-auto-pull/known-bad.txt     list of image SHAs we will not re-deploy

cd "$(dirname "${BASH_SOURCE[0]}")/.."
COMPOSE_DIR="$(pwd)"

LOG_DIR="${ASPIRANT_AUTO_PULL_LOG_DIR:-/var/log/aspirant-auto-pull}"
STATE_DIR="${ASPIRANT_AUTO_PULL_STATE_DIR:-/var/lib/aspirant-auto-pull}"
DECISIONS_LOG="${LOG_DIR}/decisions.jsonl"
KNOWN_BAD_FILE="${STATE_DIR}/known-bad.txt"

IMAGE_PREFIX="${ASPIRANT_AUTO_PULL_IMAGE_PREFIX:-ghcr.io/the-anonymous-aspirant/aspirant-}"
HEALTH_WAIT_SECONDS="${ASPIRANT_AUTO_PULL_HEALTH_WAIT:-30}"

DRY_RUN=0
TARGET_SERVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --service)       TARGET_SERVICE="$2"; shift 2 ;;
    --once)          shift ;;
    -h|--help)
      sed -n '3,18p' "$0"
      exit 0
      ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR" "$STATE_DIR"
touch "$KNOWN_BAD_FILE"

# Cron fires every 5 min; a deploy + health wait may run longer. Take an
# exclusive lock so a slow run does not race the next tick. Library-mode
# sourcing skips the lock (no main loop runs).
LOCK_FILE="${STATE_DIR}/auto-pull.lock"
if [[ "${ASPIRANT_AUTO_PULL_LIB:-0}" -ne 1 && -z "${ASPIRANT_AUTO_PULL_LOCKED:-}" ]]; then
  exec env ASPIRANT_AUTO_PULL_LOCKED=1 flock -n "$LOCK_FILE" "$0" "$@"
fi

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# log_decision SERVICE ACTION FROM_SHA TO_SHA REASON
log_decision() {
  local svc="$1" action="$2" from="$3" to="$4" reason="$5"
  printf '{"ts":"%s","service":"%s","action":"%s","from_sha":"%s","to_sha":"%s","reason":"%s"}\n' \
    "$(iso_now)" "$svc" "$action" "$from" "$to" "$reason" >> "$DECISIONS_LOG"
}

is_known_bad() {
  local sha="$1"
  [[ -n "$sha" ]] && grep -Fxq "$sha" "$KNOWN_BAD_FILE"
}

mark_known_bad() {
  local sha="$1"
  [[ -n "$sha" ]] || return 0
  is_known_bad "$sha" && return 0
  echo "$sha" >> "$KNOWN_BAD_FILE"
}

# decide ACTION_TARGET CURRENT_SHA LATEST_SHA KNOWN_BAD_FILE -> echoes one of:
#   no_change           (current == latest)
#   deferred_known_bad  (latest is in known-bad list)
#   deploy              (current != latest, latest not known-bad)
decide() {
  local current="$1" latest="$2" bad_file="$3"
  if [[ -z "$latest" ]]; then echo "skip_no_image"; return; fi
  if [[ "$current" == "$latest" ]]; then echo "no_change"; return; fi
  if [[ -s "$bad_file" ]] && grep -Fxq "$latest" "$bad_file"; then
    echo "deferred_known_bad"; return
  fi
  echo "deploy"
}

# Verify container is "running" (and not "restarting") after HEALTH_WAIT_SECONDS.
container_healthy_after_wait() {
  local container="$1"
  sleep "$HEALTH_WAIT_SECONDS"
  local status
  status="$(docker inspect "$container" --format '{{.State.Status}}' 2>/dev/null || echo "missing")"
  [[ "$status" == "running" ]]
}

list_aspirant_services() {
  # Format: SERVICE|CONTAINER|IMAGE_REF
  docker compose ps --format '{{.Service}}|{{.Name}}|{{.Image}}' 2>/dev/null \
    | awk -F'|' -v p="$IMAGE_PREFIX" '$3 ~ "^"p && $3 ~ ":latest$" { print }'
}

# Per-service handler. Echoes the action taken; non-zero exit on hard failure.
process_service() {
  local svc="$1" container="$2" image="$3"

  local current_sha latest_sha
  current_sha="$(docker inspect "$container" --format '{{.Image}}' 2>/dev/null || true)"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    docker compose pull "$svc" >/dev/null 2>&1 || true
  fi

  latest_sha="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)"

  local action
  action="$(decide "$current_sha" "$latest_sha" "$KNOWN_BAD_FILE")"

  case "$action" in
    no_change)
      log_decision "$svc" "no_change" "$current_sha" "$latest_sha" "sha_match"
      ;;
    deferred_known_bad)
      log_decision "$svc" "deferred_known_bad" "$current_sha" "$latest_sha" "previous_deploy_failed_health"
      ;;
    skip_no_image)
      log_decision "$svc" "skipped" "$current_sha" "" "image_not_pulled"
      ;;
    deploy)
      if [[ "$DRY_RUN" -eq 1 ]]; then
        log_decision "$svc" "would_deploy" "$current_sha" "$latest_sha" "dry_run"
        return 0
      fi
      deploy_service "$svc" "$container" "$current_sha" "$latest_sha"
      ;;
  esac
}

deploy_service() {
  local svc="$1" container="$2" old_sha="$3" new_sha="$4"

  # client is blue/green; defer to the existing deploy-client.sh which
  # handles slot swap + rollback. Match the *image* (client-blue and
  # client-green share aspirant-client:latest) so we only trigger once.
  if [[ "$svc" == "client-blue" || "$svc" == "client-green" ]]; then
    if ./scripts/deploy-client.sh deploy >/dev/null 2>&1; then
      log_decision "$svc" "deployed_blue_green" "$old_sha" "$new_sha" "deploy_client_ok"
    else
      mark_known_bad "$new_sha"
      log_decision "$svc" "failed_blue_green" "$old_sha" "$new_sha" "deploy_client_failed_marked_bad"
    fi
    return 0
  fi

  if docker compose up -d --force-recreate "$svc" >/dev/null 2>&1; then
    if container_healthy_after_wait "$container"; then
      log_decision "$svc" "deployed" "$old_sha" "$new_sha" "running_after_wait"
    else
      mark_known_bad "$new_sha"
      log_decision "$svc" "deployed_unhealthy" "$old_sha" "$new_sha" "not_running_after_wait_marked_bad"
    fi
  else
    mark_known_bad "$new_sha"
    log_decision "$svc" "failed_recreate" "$old_sha" "$new_sha" "compose_up_failed_marked_bad"
  fi
}

# Test-mode escape hatch: source the script with ASPIRANT_AUTO_PULL_LIB=1
# to expose decide / log_decision / is_known_bad / mark_known_bad without
# running the main loop.
if [[ "${ASPIRANT_AUTO_PULL_LIB:-0}" -eq 1 ]]; then
  return 0
fi

# Main loop.
SEEN_CLIENT=0
while IFS='|' read -r svc container image; do
  [[ -z "$svc" ]] && continue
  if [[ -n "$TARGET_SERVICE" && "$svc" != "$TARGET_SERVICE" ]]; then
    continue
  fi
  # Avoid running deploy-client.sh twice (blue + green both match).
  if [[ "$svc" == "client-blue" || "$svc" == "client-green" ]]; then
    if [[ "$SEEN_CLIENT" -eq 1 ]]; then continue; fi
    SEEN_CLIENT=1
  fi
  process_service "$svc" "$container" "$image"
done < <(list_aspirant_services)
