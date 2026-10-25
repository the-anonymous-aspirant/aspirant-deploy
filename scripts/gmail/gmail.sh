#!/usr/bin/env bash
# The one entry point for the Gmail credential and pull tools (system_3 #8806).
#
# Runs scripts/gmail/*.py inside the aspirant-gmail:local image (python 3.12 +
# google client libraries + cryptography), because the cell's host python
# carries neither. Mounts:
#   ./scripts                          read-only  (gmail/ and kek/ modules)
#   ~/secrets/gmail                    read-write (the envelope-encrypted token)
#   ~/secrets/gmail-oauth-client.json  read-only  (the operator's Desktop client)
# `--network host` so the loopback consent server on 127.0.0.1:<port> is the
# one the operator's SSH tunnel reaches. The KEK is passed through only when the
# caller exported LAKE_KEK_HEX (one-shot); otherwise the hidden prompt runs on
# the terminal. Nothing here persists key material.
#
# Usage: scripts/gmail/gmail.sh consent [--port 8765] [--note TEXT]
#        scripts/gmail/gmail.sh status [--check]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
IMAGE="${GMAIL_IMAGE:-aspirant-gmail:local}"
SECRETS="${GMAIL_SECRETS_DIR:-$HOME/secrets}"
CLIENT="$SECRETS/gmail-oauth-client.json"
TOOL="${GMAIL_TOOL:-scripts/gmail/gmail_auth.py}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "building $IMAGE from Dockerfile-Gmail ..." >&2
  docker build -q -t "$IMAGE" -f Dockerfile-Gmail . >/dev/null
fi
mkdir -p "$SECRETS/gmail"
chmod 700 "$SECRETS" "$SECRETS/gmail"

run=(docker run --rm --network host -e HOME=/root -e GMAIL_SECRETS_DIR=/secrets/gmail -e GMAIL_CLIENT_JSON=/secrets/gmail-oauth-client.json)
if [[ -t 0 && -t 1 ]]; then run+=(-it); fi
for v in LAKE_KEK_HEX LAKE_KEK_FINGERPRINT LAKE_KEK_VERSION; do
  if [[ -n "${!v:-}" ]]; then run+=(-e "$v"); fi
done
run+=(-v "$PWD/scripts:/work/scripts:ro" -v "$SECRETS/gmail:/secrets/gmail")
if [[ -f "$CLIENT" ]]; then
  run+=(-v "$CLIENT:/secrets/gmail-oauth-client.json:ro")
elif [[ "${1:-}" == "consent" ]]; then
  echo "no OAuth client JSON at $CLIENT (scp it there, mode 600; see docs/GMAIL_INGEST.md)" >&2
  exit 5
fi
exec "${run[@]}" -w /work "$IMAGE" "$TOOL" "$@"
