#!/usr/bin/env bash
# Pull the operator's mailbox and ingest the run into the lake under ONE KEK
# prompt (system_3 #8806-B2, task #8810).
#
# The pull (scripts/gmail/gmail.sh pull, #8806-B1) opens the refresh token with
# the lake KEK; the ingest runner (scripts/lake_ingest.py through
# scripts/lake-skeleton.sh ingest) wraps each object's DEK with the same KEK.
# Run separately they ask for it twice. This script reads it once, hidden,
# exports it for both children, and never prints it.
#
#   scripts/gmail/gmail_pull_and_ingest.sh            incremental pull, then ingest the run
#   scripts/gmail/gmail_pull_and_ingest.sh --full     full pull, then ingest
#   scripts/gmail/gmail_pull_and_ingest.sh --dry-run  pull for real; the ingest only reports
#   scripts/gmail/gmail_pull_and_ingest.sh --verify   ... and run verify-at-rest afterwards
#
# Exit codes: the pull's own when it fails (3 re-consent needed, 4 transport,
# 7 another pull holds the lock), in which case nothing is ingested; 2 for a
# missing KEK or a bad argument; otherwise the ingest's (0 success, 1 partial).
# A pull that finds no change writes no run directory, and this exits 0 with
# "no new run to ingest". After a successful real ingest the run directory
# (the export in clear) is deleted; after a failed or --dry-run ingest it is
# kept for a retry and named on stderr. state.json is never touched.
#
# Overridable for the unit test (tests/gmail_pull_and_ingest_unit.sh), never
# set in normal use: GMAIL_PULL_CMD, LAKE_INGEST_CMD, LAKE_VERIFY_CMD,
# GMAIL_STAGING_DIR (also honoured by gmail.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

STAGING="${GMAIL_STAGING_DIR:-/data/gmail}"
PULL_CMD="${GMAIL_PULL_CMD:-scripts/gmail/gmail.sh pull}"
INGEST_CMD="${LAKE_INGEST_CMD:-scripts/lake-skeleton.sh ingest}"
VERIFY_CMD="${LAKE_VERIFY_CMD:-scripts/lake-skeleton.sh verify-at-rest}"

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

full=0; verify=0; dry=0
for arg in "$@"; do
  case "$arg" in
    --full) full=1 ;;
    --verify) verify=1 ;;
    --dry-run) dry=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "gmail_pull_and_ingest: unknown argument '$arg' (--full, --dry-run, --verify)" >&2; exit 2 ;;
  esac
done

# One KEK for both halves. Entered hidden; or exported one-shot by the caller
# (`read -rs LAKE_KEK_HEX && export LAKE_KEK_HEX`, docs/GMAIL_INGEST.md). Never
# accepted as an argument, which would put the lake master key in the shell
# history and in `ps`.
if [[ -z "${LAKE_KEK_HEX:-}" ]]; then
  if [[ -t 0 ]]; then
    read -rs -p 'lake KEK (grouped hex, hidden): ' LAKE_KEK_HEX
    echo >&2
  else
    echo "gmail_pull_and_ingest: LAKE_KEK_HEX is not set and stdin is not a terminal;" \
         "export it one-shot with 'read -rs LAKE_KEK_HEX && export LAKE_KEK_HEX' and retry" >&2
    exit 2
  fi
fi
if [[ -z "${LAKE_KEK_HEX}" ]]; then
  echo "gmail_pull_and_ingest: empty KEK; nothing run" >&2
  exit 2
fi
export LAKE_KEK_HEX

pull_args=()
if [[ $full -eq 1 ]]; then pull_args+=(--full); fi

# The pull prints exactly one summary line on stdout (counts only) and its
# diagnostics on stderr; keep stderr flowing to the terminal and read the line.
set +e
summary="$($PULL_CMD ${pull_args[@]+"${pull_args[@]}"})"
pull_rc=$?
set -e
if [[ -n "$summary" ]]; then printf '%s\n' "$summary"; fi
if [[ $pull_rc -ne 0 ]]; then
  echo "gmail_pull_and_ingest: the pull exited $pull_rc; nothing ingested" >&2
  exit "$pull_rc"
fi

run_id="$(printf '%s\n' "$summary" | sed -nE 's/.*[[:space:]]run_id=([^[:space:]]+).*/\1/p' | tail -n 1)"
manifest="$STAGING/runs/$run_id/manifest.json"
if [[ -z "$run_id" || "$summary" == *"(no change"* || ! -f "$manifest" ]]; then
  echo "gmail_pull_and_ingest: no new run to ingest"
  exit 0
fi

ingest_args=()
if [[ $dry -eq 1 ]]; then ingest_args+=(--dry-run); fi
echo "gmail_pull_and_ingest: ingesting run_id=$run_id"
set +e
$INGEST_CMD "$manifest" ${ingest_args[@]+"${ingest_args[@]}"}
ingest_rc=$?
set -e

# The export is the operator's mail in clear. Once the lake holds its envelope
# and inventory row it has no consumer left (a re-ingest of the same bytes is
# a no-op by content address), and every agent session on the cell runs as
# this user, so the clear copy goes the moment the ingest has succeeded for
# real. A failed or dry-run ingest keeps it so a retry can load it, and says
# so, because a kept copy must never be a surprise (security review c58623).
run_dir="$STAGING/runs/$run_id"
if [[ $ingest_rc -eq 0 && $dry -eq 0 ]]; then
  rm -rf "$run_dir"
  echo "gmail_pull_and_ingest: clear export removed ($run_dir); the lake holds the envelope"
else
  echo "gmail_pull_and_ingest: clear export kept at $run_dir; re-run to ingest it" >&2
  if [[ $ingest_rc -ne 0 ]]; then exit "$ingest_rc"; fi
fi

if [[ $verify -eq 1 ]]; then
  $VERIFY_CMD
fi
