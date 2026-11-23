#!/usr/bin/env bash
#
# Bring an exited decrypt-on explorer-api back with decrypt off
# (system_3 #12207, under #12203; security c75726 on #12202, option (a)).
#
# `lake-skeleton.sh explorer-decrypt-up` starts explorer-api with the
# operator's key as a tmpfs file, and deletes the file once the service is
# healthy. dockerd cannot restart that container after a crash, a daemon
# restart or a reboot, because its bind source is gone, so the verb creates it
# with restart policy `no` and the label `aspirant.explorer.decrypt=on`. This
# script, run every minute from the operator's own crontab, finds it exited
# and runs the plain recreate, which comes back with decrypt off:
#
#   * * * * * /home/aspirant/aspirant-deploy/scripts/explorer-decrypt-off-recover.sh \
#       >> /home/aspirant/.local/state/aspirant/explorer-decrypt-off-recover.cron.log 2>&1
#
# What it never does: read, stage or name a key; read a container's
# environment; call `docker logs`; mount docker.sock into anything. Decrypt
# comes back only when the operator runs explorer-decrypt-up again.
#
# It acts only when all three hold: the container has exited, its restart
# policy is `no`, and its label is `on`. A plain container (`unless-stopped`,
# no label) is docker's to restart, and is never touched. It takes the verb's
# lock first and does nothing while the verb holds it.
#
# Each recovery appends ONE line to the log the weekly cell-health review
# reads, `<UTC time> exit=<the container's exit code>`, and nothing else. The
# line is written before the recreate; if it cannot be written, there is no
# recreate, so decrypt never goes off unrecorded.
#
# Exit: 0 when there was nothing to do, or the recovery came back healthy;
# 1 when a step failed (docker not up yet at boot, the log not writable, the
# recreate not healthy). Cron runs it again a minute later.
#
# A decrypt-on container stopped by hand (`docker stop`) looks the same to
# docker, so it too comes back with decrypt off at the next tick. To keep
# explorer-api down, `docker compose --profile explorer rm -s -f explorer-api`,
# or take the line out of the crontab.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_DIR="${ASPIRANT_DEPLOY_DIR:-$SRC_DIR}"
# The same path explorer-decrypt-up locks (scripts/lake-skeleton.sh).
LOCK_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/explorer-api-decrypt.lock"
LOG_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/aspirant/explorer-decrypt-off.log"

# At boot the runtime dir may not exist yet; the next tick retries.
exec 9>"$LOCK_FILE"
# The verb is starting it, or recovering a refused key, or another tick is
# recovering it: theirs to finish.
flock -n 9 || exit 0

cd "$DEPLOY_DIR"
cids="$(docker compose --profile explorer ps -a -q explorer-api)"

# Four fields, none of them the environment. Normally one container; a
# compose replace can briefly leave a second, so read each.
exit_code=""
for cid in $cids; do
  state="$(docker inspect --format \
    '{{.State.Status}}|{{.State.ExitCode}}|{{.HostConfig.RestartPolicy.Name}}|{{index .Config.Labels "aspirant.explorer.decrypt"}}' \
    "$cid")"
  IFS='|' read -r status code policy decrypt <<<"$state"
  if [ "$status" = exited ] && [ "$policy" = no ] && [ "$decrypt" = on ]; then
    exit_code="${code:-unknown}"
    break
  fi
done
[ -n "$exit_code" ] || exit 0
case "$exit_code" in
  *[!0-9]*) exit_code=unknown ;;
esac

mkdir -p "$(dirname "$LOG_FILE")"
printf '%s exit=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$exit_code" >>"$LOG_FILE"

# The plain recreate, as a plain `up` would run it: none of the key's
# variables, and no EXPLORER_API_RESTART, so compose gives decrypt off,
# /dev/null for the key mount, `unless-stopped` and an empty label.
env -u EXPLORER_API_RESTART -u LAKE_KEK_FILE_HOST -u LAKE_KEK_FINGERPRINT \
    -u LAKE_KEK_HEX -u LAKE_KEK_FILE \
  docker compose --profile explorer up -d --wait --wait-timeout 180 \
    --force-recreate --no-deps explorer-api
