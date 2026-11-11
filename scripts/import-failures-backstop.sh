#!/usr/bin/env bash
# Host-side backstop for the failed-import copies (system_3 #10563).
#
# aspirant-server keeps a copy of each failed invoice-import upload on the
# /data/aspirant/import-failures bind mount and deletes it when its window ends,
# from an hourly sweep inside the server process (system_3 #10536). Those files
# are the app user's own bank documents. The server sweep only runs while the
# server does, so this script deletes them independently of it: every regular
# file on the mount older than the server's hard ceiling, 168 hours, by mtime
# (security's condition, c65555 §1 on #10563).
#
# Run hourly from the `aspirant` user's crontab (docs/OPERATIONS.md,
# "Failed-import copies"):
#
#   17 * * * * /home/aspirant/aspirant-deploy/scripts/import-failures-backstop.sh >> /var/log/aspirant-import-failures/backstop.log 2>&1
#
# Exit status:
#   0  swept (or the directory does not exist yet: nothing to sweep)
#   1  a file past the ceiling could not be deleted, or part of the tree could
#      not be read; either is retried next run
#   2  the directory is not a plain directory (e.g. a symlink): refused
#
# One summary line per run. File names are server-built hashes, never the
# uploaded filename, so they are safe to log.
#
# IMPORT_FAILURE_HOST_DIR overrides the directory for tests only.

set -euo pipefail

DIR="${IMPORT_FAILURE_HOST_DIR:-/data/aspirant/import-failures}"
# 168 h, aspirant-server's importFailureMaxWindowHours. The server may run a
# shorter window; this is the backstop for the longest one it can.
MAX_AGE_MINUTES=10080
# The server container runs as uid 1000 (aspirant-server Dockerfile-Server).
SERVER_UID=1000

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf '%s import-failures-backstop: %s\n' "$(ts)" "$*"; }

if [[ -L "$DIR" ]]; then
  say "REFUSED: $DIR is a symlink; not sweeping through it"
  exit 2
fi
if [[ ! -e "$DIR" ]]; then
  say "$DIR absent; nothing to sweep"
  exit 0
fi
if [[ ! -d "$DIR" ]]; then
  say "REFUSED: $DIR is not a directory"
  exit 2
fi

# Provisioning drift is reported, never fatal: deleting old files is the job
# and must still happen. Root-owned means Docker created the mount point, so
# the server cannot write and no copies are being kept at all.
owner="$(stat -c %u "$DIR")"
mode="$(stat -c %a "$DIR")"
if [[ "$owner" != "$SERVER_UID" || "$mode" != "700" ]]; then
  say "WARNING: $DIR is uid $owner mode $mode, want uid $SERVER_UID mode 700 (docs/OPERATIONS.md, Failed-import copies)"
fi

list="$(mktemp)"
errs="$(mktemp)"
trap 'rm -f "$list" "$errs"' EXIT

# A part of the tree find cannot read would hide its files from the sweep, so
# that is a failure too, not a quiet skip.
unreadable=0
if ! find "$DIR" -xdev -mindepth 1 -type f -mmin +"$MAX_AGE_MINUTES" -print0 >"$list" 2>"$errs"; then
  unreadable=1
  say "FAILED to read all of $DIR: $(tr '\n' ' ' <"$errs" | head -c 300)"
fi

deleted=0
failed=0
while IFS= read -r -d '' f; do
  if rm -f -- "$f" 2>/dev/null && [[ ! -e "$f" ]]; then
    deleted=$((deleted + 1))
  else
    failed=$((failed + 1))
    say "FAILED to delete ${f#"$DIR"/}; retrying next run"
  fi
done <"$list"

say "deleted=$deleted failed=$failed unreadable=$unreadable older_than=${MAX_AGE_MINUTES}m dir=$DIR"
if (( failed > 0 || unreadable > 0 )); then
  exit 1
fi
