#!/usr/bin/env bash
set -euo pipefail

# Unit tests for the tor sidecar's image pin in both compose files
# (system_3 #9083). The predecessor, dperson/torproxy:latest, was an
# unmaintained floating tag whose Tor the network consensus stopped
# accepting; nothing pulls a digest-pinned image behind our back, so the
# pin is the upgrade decision and this checks it stays one. No docker or
# network required.
#
# Usage: ./tests/tor_image_pin_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0
FAIL=0

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %s — expected %q got %q\n" "$label" "$expected" "$actual"
  fi
}

# tor_field FILE FIELD prints services.tor.FIELD as JSON.
tor_field() {
  python3 -c '
import json, sys, yaml
svc = yaml.safe_load(open(sys.argv[1]))["services"]["tor"]
print(json.dumps(svc.get(sys.argv[2])))
' "$1" "$2"
}

PIN_RE='^"osminogin/tor-simple:[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}"$'
STDOUT_CMD='["tor", "-f", "/etc/tor/torrc", "--Log", "notice stdout"]'

for f in docker-compose.yml docker-compose.dev.yml; do
  image="$(tor_field "$f" image)"
  assert_eq "1" "$(grep -cE "$PIN_RE" <<<"$image" || true)" \
    "$f: tor image is a versioned tag pinned by digest"
  assert_eq "$STDOUT_CMD" "$(tor_field "$f" command)" \
    "$f: tor logs to stdout, where docker logs and the json-file cap see it"
done

assert_eq "$(tor_field docker-compose.yml image)" \
  "$(tor_field docker-compose.dev.yml image)" \
  "dev and production compose pin the same tor image"

# browser reaches Tor at tor:9050, the only port the image's torrc opens.
assert_eq '"socks5://tor:9050"' \
  "$(python3 -c '
import json, yaml
print(json.dumps(yaml.safe_load(open("docker-compose.yml"))["services"]["browser"]["environment"]["TOR_SOCKS_URL"]))
')" "browser's TOR_SOCKS_URL is the sidecar's SOCKS port"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
