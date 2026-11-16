#!/usr/bin/env bash
# The one entry point for the Gmail credential and pull tools (system_3 #8806).
#
# Runs scripts/gmail/*.py inside the aspirant-gmail:local image (python 3.12 +
# google client libraries + cryptography), because the cell's host python
# carries neither. Mounts:
#   ./scripts                          read-only  (gmail/ and kek/ modules)
#   ~/secrets/gmail                    read-write (the envelope-encrypted token)
#   ~/secrets/gmail-oauth-client.json  read-only  (the operator's Desktop client)
#   /data/gmail                        read-write (`pull` only: the export staging
#                                      dir on the LUKS volume; GMAIL_STAGING_DIR overrides)
# `--network host` for `consent` only, so the loopback consent server on
# 127.0.0.1:<port> is the one the operator's SSH tunnel reaches; other commands
# get the default bridge network (egress only). Runs as the invoking user, not
# root.
#
# The KEK reaches the container on a pipe, never on `-e` and never in a file
# held for the run (security c70261 on #11344): `-e` values are persisted by
# dockerd and shown by `docker inspect` (#10354), and a key file or an
# environment block can be read by any same-uid process for as long as it
# exists. A caller that holds it passes LAKE_KEK_FILE=<path> to read it from
# once, typically /dev/fd/3 fed by a here-string
# (scripts/gmail/gmail_pull_and_ingest.sh); it is read into an unexported
# variable and written to the container's stdin, where kek_loader reads
# LAKE_KEK_FILE=/dev/stdin (a 0600 pipe). Without it, the container's own
# hidden prompt runs on the terminal. An exported LAKE_KEK_HEX is refused: it
# would stay in this process's own /proc/<pid>/environ for the whole run, even
# after `unset` (security F1, c70270 on #11428).
#
# Usage: scripts/gmail/gmail.sh consent [--port 8765] [--note TEXT]
#        scripts/gmail/gmail.sh status [--check]
#        scripts/gmail/gmail.sh pull [--full]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
IMAGE="${GMAIL_IMAGE:-aspirant-gmail:local}"
SECRETS="${GMAIL_SECRETS_DIR:-$HOME/secrets}"
CLIENT="$SECRETS/gmail-oauth-client.json"
STAGING="${GMAIL_STAGING_DIR:-/data/gmail}"
TOOL="${GMAIL_TOOL:-scripts/gmail/gmail_auth.py}"
if [[ "${1:-}" == "pull" ]]; then
  TOOL="${GMAIL_TOOL:-scripts/gmail/gmail_pull.py}"
  shift
  pull=1
else
  pull=0
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "building $IMAGE from Dockerfile-Gmail ..." >&2
  docker build -q -t "$IMAGE" -f Dockerfile-Gmail . >/dev/null
fi
mkdir -p "$SECRETS/gmail"
chmod 700 "$SECRETS" "$SECRETS/gmail"

# Non-root: the token files land on the host owned by the invoking user, and the
# process that holds the KEK does not run as root. Host networking only for
# `consent`, whose loopback server the operator's SSH tunnel must reach; every
# other command needs egress only (review c54457).
run=(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e GMAIL_SECRETS_DIR=/secrets/gmail -e GMAIL_CLIENT_JSON=/secrets/gmail-oauth-client.json)
if [[ "${1:-}" == "consent" ]]; then run+=(--network host); fi
# The key, if the caller supplied one, into an unexported variable. Neither
# variable is passed on: the container gets the key on stdin below.
if [[ -n "${LAKE_KEK_HEX:-}" ]]; then
  echo "refusing an exported LAKE_KEK_HEX: it would sit in this process's environment for the" \
       "whole run. Unset it ('unset LAKE_KEK_HEX') and type the KEK at the prompt." >&2
  exit 2
fi
kek=""
if [[ -n "${LAKE_KEK_FILE:-}" ]]; then
  if ! kek="$(<"$LAKE_KEK_FILE")"; then
    echo "refusing: cannot read the KEK from LAKE_KEK_FILE" >&2
    exit 1
  fi
fi
unset LAKE_KEK_FILE
if [[ -n "$kek" ]]; then
  # The key goes in on stdin, so the container runs without a terminal;
  # nothing the tools run with a key in hand reads the terminal.
  run+=(-i -e LAKE_KEK_FILE=/dev/stdin)
elif [[ -t 0 && -t 1 ]]; then
  run+=(-it)
fi
# LAKE_KEK_FINGERPRINT and LAKE_KEK_VERSION are not secret (the fingerprint is
# a one-way hash, the version a small int) and stay on `-e`.
for v in LAKE_KEK_FINGERPRINT LAKE_KEK_VERSION; do
  if [[ -n "${!v:-}" ]]; then run+=(-e "$v"); fi
done
# `pull` only reads the token, so it gets the secrets dir read-only (security
# review on #8809); `consent` writes it.
secrets_mode=""
if [[ $pull -eq 1 ]]; then secrets_mode=":ro"; fi
run+=(-v "$PWD/scripts:/work/scripts:ro" -v "$SECRETS/gmail:/secrets/gmail$secrets_mode")
if [[ $pull -eq 1 ]]; then
  # The exports are mail in clear until the lake ingest (#8806-B2) encrypts
  # them, so they live only on the LUKS volume, in a dir only this user reads.
  mkdir -p "$STAGING"
  chmod 700 "$STAGING"
  run+=(-v "$STAGING:/staging" -e GMAIL_STAGING_DIR=/staging)
fi
if [[ -f "$CLIENT" ]]; then
  run+=(-v "$CLIENT:/secrets/gmail-oauth-client.json:ro")
elif [[ "${1:-}" == "consent" ]]; then
  echo "no OAuth client JSON at $CLIENT (scp it there, mode 600; see docs/GMAIL_INGEST.md)" >&2
  exit 5
fi
if [[ -n "$kek" ]]; then
  "${run[@]}" -w /work "$IMAGE" "$TOOL" "$@" <<<"$kek"
else
  "${run[@]}" -w /work "$IMAGE" "$TOOL" "$@"
fi
