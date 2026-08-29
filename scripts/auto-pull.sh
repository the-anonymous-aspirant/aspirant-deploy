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
#
# Gates (checked once per run, before any pull or recreate):
#   1. Maintenance pause — if .maintenance-pause exists in this checkout, the
#      run is a logged no-op. Lets an operator freeze deploys mid-cutover
#      without editing the crontab. Exits 0: a sanctioned freeze is not a fault.
#   2. Checkout provenance — this script drives `docker compose` against the
#      docker-compose.yml in THIS checkout, so a checkout parked on a feature
#      branch would recreate production services from the wrong compose file.
#      Refuses to act unless HEAD is `main` tracking `origin/main`. Exits 1.
#   3. Checkout freshness — fetches origin and, when HEAD is behind origin/main,
#      fast-forwards the checkout if git can prove that loses nothing (no
#      tracked changes, HEAD an ancestor of origin/main). Logs `checkout_ff`
#      on success and `checkout_stale` with the refusal reason otherwise;
#      never blocks the image sweep either way.
#   Gates 1 and 2 do not inspect the working tree for uncommitted or untracked
#   files; the cell carries stray .bak files and they are not a provenance
#   signal. Gate 3 looks at TRACKED changes only, and only to decide whether a
#   fast-forward is lossless — untracked files never block it either.

cd "$(dirname "${BASH_SOURCE[0]}")/.."
COMPOSE_DIR="$(pwd)"

LOG_DIR="${ASPIRANT_AUTO_PULL_LOG_DIR:-/var/log/aspirant-auto-pull}"
STATE_DIR="${ASPIRANT_AUTO_PULL_STATE_DIR:-/var/lib/aspirant-auto-pull}"
DECISIONS_LOG="${LOG_DIR}/decisions.jsonl"
KNOWN_BAD_FILE="${STATE_DIR}/known-bad.txt"

IMAGE_PREFIX="${ASPIRANT_AUTO_PULL_IMAGE_PREFIX:-ghcr.io/the-anonymous-aspirant/aspirant-}"
HEALTH_WAIT_SECONDS="${ASPIRANT_AUTO_PULL_HEALTH_WAIT:-30}"

# Maintenance-pause marker. Same filename and same presence-is-the-signal
# contract as the system_3 side (shared/paths.py::MAINTENANCE_MARKER_NAME), but
# resolved against THIS checkout: the two hosts share no filesystem, so one
# marker per box is the most a file-based contract can offer. Contents are
# advisory only — never read, so an unreadable marker cannot crash the cron.
MAINTENANCE_MARKER="${ASPIRANT_MAINTENANCE_MARKER:-${COMPOSE_DIR}/.maintenance-pause}"

DRY_RUN=0
TARGET_SERVICE=""

# Keep the original argv for the lock re-exec below: the parse loop consumes
# "$@" with shift, and re-execing with the emptied "$@" silently dropped every
# flag on the locked path — `--dry-run` deployed for real and `--service`
# swept everything (found by the cron-shape test in tests/auto_pull_unit.sh,
# system_3 #4537).
ORIG_ARGS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --service)       TARGET_SERVICE="$2"; shift 2 ;;
    --once)          shift ;;
    -h|--help)
      sed -n '4,30p' "$0"
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
  exec env ASPIRANT_AUTO_PULL_LOCKED=1 flock -n "$LOCK_FILE" "$0" "${ORIG_ARGS[@]}"
fi

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# log_decision SERVICE ACTION FROM_SHA TO_SHA REASON
log_decision() {
  local svc="$1" action="$2" from="$3" to="$4" reason="$5"
  printf '{"ts":"%s","service":"%s","action":"%s","from_sha":"%s","to_sha":"%s","reason":"%s"}\n' \
    "$(iso_now)" "$svc" "$action" "$from" "$to" "$reason" >> "$DECISIONS_LOG"
}

# maintenance_paused MARKER_PATH -> true when a freeze window is open.
# Presence alone is the signal; the file is deliberately never read.
maintenance_paused() {
  [[ -e "$1" ]]
}

# checkout_provenance DIR -> echoes "ok", or a reason token naming the drift.
# Guards the compose file this script deploys from, so anything that leaves us
# unable to *prove* the checkout is release-tracking counts as drift — an
# absent git binary and a detached HEAD are both refusals, not pass-throughs.
checkout_provenance() {
  local dir="$1" branch upstream
  branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "$branch" ]]; then
    echo "not_a_git_checkout"; return
  fi
  if [[ "$branch" != "main" ]]; then
    # Detached HEAD reports the literal string "HEAD" and lands here too.
    echo "branch_not_main:${branch}"; return
  fi
  upstream="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
  if [[ "$upstream" != "origin/main" ]]; then
    echo "upstream_not_origin_main:${upstream:-none}"; return
  fi
  echo "ok"
}

# checkout_freshness DIR -> echoes "current", "behind:N", or "unknown:<reason>".
#
# The provenance gate above proves the checkout is on main tracking origin/main.
# It does NOT prove the checkout is CURRENT, and OPERATIONS.md §Deploy gates
# states that gate's own intent as "the gate needs to prove provenance, not
# merely fail to disprove it". A checkout six PRs behind on main is unproven
# fresh and passes it cleanly.
#
# That is not hypothetical: on 2026-07-20 the cell was found at PR #50 while
# origin/main was at #56 (system_3 #2520). Nothing on the cell has ever pulled
# this checkout — auto-pull.sh polls IMAGES and contains no git operation, and
# no other cron does either — so every pull has been a hand action at multi-day
# intervals. Meanwhile this script drives `docker compose` against the compose
# file in THIS checkout, so image updates were still being applied every five
# minutes from six-PR-old config, silently. Stale docs were never the risk.
#
# Read-only and best-effort. The fetch touches the network, so a failure here
# (offline cell, dead uplink — both routine on this host) reports `unknown` and
# never blocks: a detector that turns a flaky uplink into a deploy outage would
# be a worse defect than the one it reports.
checkout_freshness() {
  local dir="$1" behind
  if [[ "${ASPIRANT_AUTO_PULL_SKIP_FETCH:-0}" -ne 1 ]]; then
    git -C "$dir" fetch origin --quiet 2>/dev/null || { echo "unknown:fetch_failed"; return; }
  fi
  behind="$(git -C "$dir" rev-list --count HEAD..origin/main 2>/dev/null || true)"
  if [[ -z "$behind" ]]; then
    echo "unknown:no_rev_list"; return
  fi
  if [[ "$behind" -eq 0 ]]; then
    echo "current"; return
  fi
  echo "behind:${behind}"
}

# checkout_ff_preflight DIR -> echoes "ok" when a fast-forward of DIR onto
# origin/main is provably lossless, else a reason token:
#   refused:tracked_changes    a tracked file is modified or staged — someone is
#                              mid-edit in the deploy tree; a merge would touch
#                              their work. Untracked files are ignored, for the
#                              same reason gates 1 and 2 ignore them.
#   refused:not_fast_forward   HEAD is not an ancestor of origin/main — there is
#                              a local commit on main. Only a human can say
#                              whether it is a hotfix or a mistake.
# Assumes origin/main was fetched just before (checkout_freshness does that);
# this function itself touches no network.
checkout_ff_preflight() {
  local dir="$1"
  if [[ -n "$(git -C "$dir" status --porcelain --untracked-files=no 2>/dev/null)" ]]; then
    echo "refused:tracked_changes"; return
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    echo "refused:not_fast_forward"; return
  fi
  echo "ok"
}

# checkout_ff DIR -> fast-forwards DIR onto origin/main when the preflight
# passes. Echoes "ff:<old-sha>..<new-sha>" on success, the preflight's refusal
# token when it does not run, or "failed:merge" when git itself declined.
#
# Why a fast-forward is safe to run from a cron tick: `--ff-only` creates no
# commit and rewrites no history — the checkout ends at exactly the commit
# origin/main already is, the one every PR merge reviewed. And git replaces
# files by writing a new inode, so the copy of THIS script that bash is
# executing keeps reading the old inode to the end of the tick; the next tick
# runs the new one. (Verified 2026-08-29 on git 2.43: a running script whose
# file was fast-forwarded underneath it printed its old tail unchanged.)
checkout_ff() {
  local dir="$1" pre old new
  pre="$(checkout_ff_preflight "$dir")"
  if [[ "$pre" != "ok" ]]; then
    echo "$pre"; return
  fi
  old="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  if ! git -C "$dir" merge --ff-only --quiet origin/main >/dev/null 2>&1; then
    echo "failed:merge"; return
  fi
  new="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
  echo "ff:${old}..${new}"
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

# is_polled_image_ref IMAGE_REF -> true when the ref is one this sweep owns:
# under $IMAGE_PREFIX and floating on :latest (digest-pinned refs are not).
is_polled_image_ref() {
  local ref="$1"
  [[ "$ref" == "$IMAGE_PREFIX"* && "$ref" == *:latest ]]
}

# select_polled_services reads SERVICE|CONTAINER|IMAGE_REF lines on stdin and
# echoes the ones whose IMAGE_REF is_polled_image_ref. Pure; unit-tested.
select_polled_services() {
  local svc container ref
  while IFS='|' read -r svc container ref; do
    [[ -z "$svc" || -z "$container" ]] && continue
    if is_polled_image_ref "$ref"; then
      printf '%s|%s|%s\n' "$svc" "$container" "$ref"
    fi
  done
}

list_aspirant_services() {
  # Format: SERVICE|CONTAINER|IMAGE_REF
  #
  # IMAGE_REF is the ref the container was CREATED from (.Config.Image — the
  # compose file's `image:` string), not the ref `docker compose ps` prints for
  # it. The ps column is resolved through the local tag store: it reads
  # `…:latest` only while that tag still points at the running image, and a
  # bare `sha256:…` once the tag has moved on. Two things move it: a hand
  # `docker pull` (system_3 #4184, 2026-08-23) and this script's own failed
  # blue/green deploy (#4489, 2026-08-26) — `docker compose pull` re-points
  # `:latest` at the candidate before deploy-client.sh health-checks it, and
  # a rollback leaves the tag on the rejected image. Filtering on the ps
  # column then dropped client-* from every later tick, and 20 merged
  # aspirant-client PRs sat undeployed for two days with no decision line
  # saying so. The create-time ref does not move, so a service stays in the
  # sweep for as long as its compose entry says :latest.
  local svc container ref
  while IFS='|' read -r svc container; do
    [[ -z "$svc" ]] && continue
    ref="$(docker inspect "$container" --format '{{.Config.Image}}' 2>/dev/null || true)"
    printf '%s|%s|%s\n' "$svc" "$container" "$ref"
  done < <(docker compose ps --format '{{.Service}}|{{.Name}}' 2>/dev/null) \
    | select_polled_services
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
# to expose decide / log_decision / is_known_bad / mark_known_bad /
# is_polled_image_ref / select_polled_services / checkout_ff_preflight /
# checkout_ff without running the main loop.
if [[ "${ASPIRANT_AUTO_PULL_LIB:-0}" -eq 1 ]]; then
  return 0
fi

# Gate 1 — maintenance freeze. A sanctioned no-op, so exit 0.
if maintenance_paused "$MAINTENANCE_MARKER"; then
  printf '[%s] auto-pull: PAUSED — maintenance marker present at %s. No image will be pulled and no service recreated this tick. Remove the marker to resume.\n' \
    "$(iso_now)" "$MAINTENANCE_MARKER" >&2
  log_decision "-" "paused_maintenance" "" "" "maintenance_marker_present"
  exit 0
fi

# Gate 2 — compose-file provenance. A refusal, so exit non-zero: a run that
# declined to do its job must not report success to whatever reads the code.
PROVENANCE="$(checkout_provenance "$COMPOSE_DIR")"
if [[ "$PROVENANCE" != "ok" ]]; then
  printf '[%s] auto-pull: REFUSING TO DEPLOY — the deploy checkout at %s is not on main tracking origin/main (%s). Recreating services now would deploy them from an unreviewed docker-compose.yml. No image pulled, no service touched. Fix with:\n  git -C %s checkout main && git -C %s branch --set-upstream-to=origin/main main\n' \
    "$(iso_now)" "$COMPOSE_DIR" "$PROVENANCE" "$COMPOSE_DIR" "$COMPOSE_DIR" >&2
  log_decision "-" "refused_checkout_drift" "" "" "$PROVENANCE"
  exit 1
fi

# Gate 3 — checkout freshness. On drift, FAST-FORWARDS the checkout when git
# can prove that loses nothing, and reports either way. The image sweep
# continues in both cases: a config lag must not become an image-deploy outage.
#
# History. #2534 shipped this gate report-only and left "should staleness
# escalate to a refusal?" as an open operator decision. The answer that
# actually happened was neither: `checkout_stale` fired on essentially every
# tick from 2026-07-20 to 2026-08-29 — 40 days, behind:11 by the end (system_3
# #4537) — and nobody pulled, because a log line that never changes what the
# next tick does is furniture, not a signal. A refusal was the wrong
# escalation (it would wedge every image deploy over a compose-file lag), but
# the fast-forward was never an escalation at all: it is the exact command the
# warning was asking a human to run, done by the process that already knows
# it is needed, restricted to the case where git proves it is lossless. Every
# other case still logs `checkout_stale`, now WITH the reason it could not
# self-heal, which is the part a human has to act on.
#
# Under --dry-run the checkout is not touched; the tick logs what it would do.
FRESHNESS="$(checkout_freshness "$COMPOSE_DIR")"
case "$FRESHNESS" in
  current) ;;
  behind:*)
    if [[ "$DRY_RUN" -eq 1 ]]; then
      # One line, carrying the preflight verdict: `behind:N;ok` or `behind:N;refused:…`.
      log_decision "-" "would_checkout_ff" "" "" "${FRESHNESS};$(checkout_ff_preflight "$COMPOSE_DIR")"
    else
      FF="$(checkout_ff "$COMPOSE_DIR")"
      case "$FF" in
        ff:*)
          FF_RANGE="${FF#ff:}"
          printf '[%s] auto-pull: CHECKOUT FAST-FORWARDED — %s was %s commit(s) behind origin/main, now at %s. The rest of this tick deploys from the released docker-compose.yml; the next tick runs the released copy of this script.\n' \
            "$(iso_now)" "$COMPOSE_DIR" "${FRESHNESS#behind:}" "${FF_RANGE#*..}" >&2
          log_decision "-" "checkout_ff" "${FF_RANGE%..*}" "${FF_RANGE#*..}" "$FRESHNESS"
          ;;
        *)
          printf '[%s] auto-pull: CHECKOUT STALE — %s is %s commit(s) behind origin/main and was NOT fast-forwarded (%s). Services will still be recreated, but from THIS checkout'"'"'s docker-compose.yml, which is not the released one. Resolve the reason, or bring it current by hand:\n  git -C %s pull --ff-only\n' \
            "$(iso_now)" "$COMPOSE_DIR" "${FRESHNESS#behind:}" "$FF" "$COMPOSE_DIR" >&2
          log_decision "-" "checkout_stale" "" "" "${FRESHNESS};${FF}"
          ;;
      esac
    fi
    ;;
  *)
    # Could not determine freshness. Reported, never fatal — see checkout_freshness.
    log_decision "-" "checkout_freshness_unknown" "" "" "$FRESHNESS"
    ;;
esac

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
