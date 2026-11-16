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
#   scripts/gmail/gmail_pull_and_ingest.sh --detach [--full ...]
#                                   ask for the KEK here, then run the rest as a
#                                   systemd user unit that outlives this SSH
#                                   session; prints the unit, its log and how to stop it
#
# The KEK is never in an environment (security c70261 on #11344): it is held in
# an unexported variable here and handed to each child on a pipe, fd 3, named
# by LAKE_KEK_FILE=/dev/fd/3, at the moment that child starts. A detached run
# gets it through a 0600 file on the runtime tmpfs whose PATH alone is in the
# unit; the detached instance reads it and deletes it at once.
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
  # The leading comment block, whatever its length.
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

full=0; verify=0; dry=0; detach=0; detached=0
passthrough=()
for arg in "$@"; do
  case "$arg" in
    --full) full=1; passthrough+=("$arg") ;;
    --verify) verify=1; passthrough+=("$arg") ;;
    --dry-run) dry=1; passthrough+=("$arg") ;;
    --detach) detach=1 ;;
    --kek-from-file) detached=1 ;;  # internal: the detached instance
    -h|--help) usage; exit 0 ;;
    *) echo "gmail_pull_and_ingest: unknown argument '$arg' (--full, --dry-run, --verify, --detach)" >&2; exit 2 ;;
  esac
done

# An exported LAKE_KEK_HEX is refused, not taken over (security F1, c70270 on
# #11428): `unset` keeps it from children, but this process's own
# /proc/<pid>/environ keeps the block it started with, for the whole run. The
# hidden prompt and --detach cover every documented use.
if [[ -n "${LAKE_KEK_HEX:-}" ]]; then
  echo "gmail_pull_and_ingest: refusing an exported LAKE_KEK_HEX: it would sit in this process's" \
       "environment for the whole run. Unset it ('unset LAKE_KEK_HEX') and type the KEK at the prompt." >&2
  exit 2
fi

# One KEK for both halves, in an UNEXPORTED variable, entered at the hidden
# prompt (or, in the detached instance, read from the hand-off file). Never
# accepted as an argument, which would put the lake master key in the shell
# history and in `ps`.
kek=""
if [[ $detached -eq 1 ]]; then
  # The detached instance: read the hand-off file once and delete it now, so
  # it exists for seconds, not for the run.
  if [[ -z "${LAKE_KEK_FILE:-}" || ! -f "$LAKE_KEK_FILE" ]]; then
    echo "gmail_pull_and_ingest: --kek-from-file without a readable LAKE_KEK_FILE" >&2
    exit 2
  fi
  kek="$(<"$LAKE_KEK_FILE")"
  rm -f "$LAKE_KEK_FILE"
  unset LAKE_KEK_FILE
elif [[ -t 0 ]]; then
  read -rs -p 'lake KEK (grouped hex, hidden): ' kek
  echo >&2
else
  echo "gmail_pull_and_ingest: stdin is not a terminal; run it from a terminal to be asked for the KEK" \
       "(add --detach to let it finish after you log out)" >&2
  exit 2
fi
if [[ -z "$kek" ]]; then
  echo "gmail_pull_and_ingest: empty KEK; nothing run" >&2
  exit 2
fi

# --detach: hand the key to a systemd user unit through a 0600 tmpfs file whose
# path alone is in the unit (so `systemctl --user show` reveals no key), and
# return. Linger keeps user units alive after this SSH session ends.
if [[ $detach -eq 1 ]]; then
  # systemd-run --user finds the user manager's bus through XDG_RUNTIME_DIR,
  # which a non-login shell may not set.
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  runtime_dir="$XDG_RUNTIME_DIR"
  fstype="$(stat -f -c %T "$runtime_dir" 2>/dev/null || echo "unreadable")"
  if [[ "$fstype" != "tmpfs" ]]; then
    echo "refusing: \$XDG_RUNTIME_DIR ($runtime_dir) is not tmpfs (filesystem: $fstype)" \
         "— a real KEK must never be staged to a persistent disk" >&2
    exit 1
  fi
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  unit="gmail-pull-$stamp"
  mkdir -p "$STAGING"
  chmod 700 "$STAGING"
  log="$STAGING/pull-$stamp.log"
  (umask 077 && : >"$log")
  handoff="$(mktemp "$runtime_dir/gmail_kek.XXXXXX")"
  chmod 600 "$handoff"
  printf '%s' "$kek" >"$handoff"
  kek=""
  setenv=(-E "LAKE_KEK_FILE=$handoff")
  for v in LAKE_KEK_FINGERPRINT LAKE_KEK_VERSION GMAIL_STAGING_DIR GMAIL_SECRETS_DIR GMAIL_UNITS_PER_MINUTE \
           GMAIL_PULL_CMD LAKE_INGEST_CMD LAKE_VERIFY_CMD; do
    if [[ -n "${!v:-}" ]]; then setenv+=(-E "$v=${!v}"); fi
  done
  if ! systemd-run --user --quiet --collect --unit "$unit" --working-directory "$PWD" \
        -p "StandardOutput=append:$log" -p "StandardError=append:$log" "${setenv[@]}" \
        -- bash "$PWD/scripts/gmail/gmail_pull_and_ingest.sh" --kek-from-file ${passthrough[@]+"${passthrough[@]}"}; then
    rm -f "$handoff"
    echo "gmail_pull_and_ingest: could not start the detached unit; nothing run" >&2
    exit 1
  fi
  # The unit deletes the hand-off file as its first act; wait for that, so a
  # unit that never got going does not leave the key on the tmpfs.
  for _ in $(seq 1 60); do
    [[ -e "$handoff" ]] || break
    sleep 0.5
  done
  if [[ -e "$handoff" ]]; then
    systemctl --user stop "$unit" 2>/dev/null || true
    rm -f "$handoff"
    echo "gmail_pull_and_ingest: the detached unit did not take the key within 30 s; stopped it" >&2
    exit 1
  fi
  echo "gmail_pull_and_ingest: running detached as $unit; you can log out."
  echo "  follow:  tail -f $log"
  echo "  status:  systemctl --user status $unit"
  echo "  stop:    systemctl --user stop $unit"
  exit 0
fi

pull_args=()
if [[ $full -eq 1 ]]; then pull_args+=(--full); fi

# The pull prints exactly one summary line on stdout (counts only) and its
# diagnostics on stderr; keep stderr flowing to the terminal and read the line.
set +e
summary="$(LAKE_KEK_FILE=/dev/fd/3 $PULL_CMD ${pull_args[@]+"${pull_args[@]}"} 3<<<"$kek")"
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
LAKE_KEK_FILE=/dev/fd/3 $INGEST_CMD "$manifest" ${ingest_args[@]+"${ingest_args[@]}"} 3<<<"$kek"
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
  LAKE_KEK_FILE=/dev/fd/3 $VERIFY_CMD 3<<<"$kek"
fi
