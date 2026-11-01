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
# root. The KEK is passed through only when the caller exported LAKE_KEK_HEX
# (one-shot, entered with `read -rs`, never typed on a command line); otherwise
# the hidden prompt runs on the terminal. Nothing here persists key material.
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
if [[ -t 0 && -t 1 ]]; then run+=(-it); fi
for v in LAKE_KEK_HEX LAKE_KEK_FINGERPRINT LAKE_KEK_VERSION; do
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
exec "${run[@]}" -w /work "$IMAGE" "$TOOL" "$@"
