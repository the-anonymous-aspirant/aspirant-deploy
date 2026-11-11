#!/usr/bin/env bash
set -euo pipefail

# docker-socket-proxy-write (system_3 #10514) is a second, separate
# docker-socket-proxy sidecar carrying the ONE write capability the admin
# start/stop control needs -- deliberately not the same sidecar the rest of
# the cell reads through. Its whole safety property is narrowness:
#
#   1. It must never carry CONTAINERS=1 (or any truthy CONTAINERS value) --
#      that flag is a blanket `^/containers` path match with no method
#      restriction of its own (confirmed against the real haproxy.cfg this
#      image ships, not assumed), so combined with POST=1 it would grant
#      create/remove/rename/kill/exec-create on any container, not just
#      start/stop.
#   2. It must actually carry POST=1, ALLOW_START=1, ALLOW_STOP=1 -- the
#      feature this sidecar exists for.
#   3. Only `monitor` may reference DOCKER_SOCKET_WRITE or share a network
#      with it -- no other service gets a path to this socket.
#
# This test keeps all three true in every committed docker-compose*.yml.
#
# Usage: ./tests/compose_docker_write_proxy_scope_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

record() {
  local ok="$1" label="$2"
  if [[ "$ok" == "yes" ]]; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %s\n" "$label"
  fi
}

# check_file <path>: prints one line per violation and exits non-zero if any
# of the three properties above do not hold.
check_file() {
  python3 - "$1" <<'EOF'
import re
import sys
import yaml

SERVICE = "docker-socket-proxy-write"
# The pre-existing read-only proxy already shares docker_proxy_net with
# monitor; it was there before this sidecar and shares no capability with
# it (neither proxy calls the other). What this guards against is an
# application container gaining a path to the write proxy.
ALLOWED_MEMBERS = {"monitor", SERVICE, "docker-socket-proxy"}

services = (yaml.safe_load(open(sys.argv[1])) or {}).get("services") or {}
bad = 0

proxy = services.get(SERVICE)
if proxy is not None:
    env = proxy.get("environment") or {}
    pairs = env.items() if isinstance(env, dict) else (
        (e.split("=", 1) + [""])[:2] for e in env)
    pairs = dict(pairs)

    def truthy(v):
        return str(v).strip() not in ("", "0", "false", "False", "no")

    if truthy(pairs.get("CONTAINERS", "0")):
        print(f"{SERVICE} carries a truthy CONTAINERS -- blanket read/write on /containers")
        bad += 1
    for must in ("POST", "ALLOW_START", "ALLOW_STOP"):
        if not truthy(pairs.get(must, "0")):
            print(f"{SERVICE} does not carry a truthy {must} -- the feature would be inert")
            bad += 1

    def nets(spec):
        n = (spec or {}).get("networks")
        if n is None:
            return set()
        if isinstance(n, dict):
            return set(n.keys())
        return set(n)

    proxy_nets = nets(proxy)
    for name, spec in services.items():
        if name in ALLOWED_MEMBERS:
            continue
        if nets(spec) & proxy_nets:
            print(f"{name} shares a network with {SERVICE}: {nets(spec) & proxy_nets}")
            bad += 1
        env2 = (spec or {}).get("environment") or {}
        text = str(env2)
        if re.search(r"DOCKER_SOCKET_WRITE", text):
            print(f"{name} references DOCKER_SOCKET_WRITE")
            bad += 1

sys.exit(1 if bad else 0)
EOF
}

# Negative controls: each way the write proxy's scope could widen.
cat > "$TMPDIR_TEST/containers_on.yml" <<'EOF'
services:
  docker-socket-proxy-write:
    environment:
      CONTAINERS: 1
      POST: 1
      ALLOW_START: 1
      ALLOW_STOP: 1
  monitor:
    networks: [docker_proxy_net]
EOF
cat > "$TMPDIR_TEST/no_allow_start.yml" <<'EOF'
services:
  docker-socket-proxy-write:
    environment:
      POST: 1
      ALLOW_STOP: 1
  monitor:
    networks: [docker_proxy_net]
EOF
cat > "$TMPDIR_TEST/extra_member.yml" <<'EOF'
services:
  docker-socket-proxy-write:
    environment:
      POST: 1
      ALLOW_START: 1
      ALLOW_STOP: 1
    networks: [docker_proxy_net]
  monitor:
    networks: [docker_proxy_net]
  advisor:
    networks: [docker_proxy_net]
EOF
cat > "$TMPDIR_TEST/extra_env_ref.yml" <<'EOF'
services:
  docker-socket-proxy-write:
    environment:
      POST: 1
      ALLOW_START: 1
      ALLOW_STOP: 1
  monitor:
    networks: [docker_proxy_net]
  browser:
    environment:
      DOCKER_SOCKET_WRITE: tcp://docker-socket-proxy-write:2375
EOF
cat > "$TMPDIR_TEST/good.yml" <<'EOF'
services:
  docker-socket-proxy-write:
    environment:
      POST: 1
      ALLOW_START: 1
      ALLOW_STOP: 1
    networks: [docker_proxy_net]
  monitor:
    networks: [docker_proxy_net]
    environment:
      DOCKER_SOCKET_WRITE: tcp://docker-socket-proxy-write:2375
  advisor:
    networks: [default]
EOF

for bad in containers_on no_allow_start extra_member extra_env_ref; do
  if check_file "$TMPDIR_TEST/$bad.yml" >/dev/null; then
    record no "negative control ($bad): the check refuses it"
  else
    record yes "negative control ($bad): the check refuses it"
  fi
done

if check_file "$TMPDIR_TEST/good.yml" >/dev/null; then
  record yes "positive control (good): a correctly-scoped file passes"
else
  record no "positive control (good): a correctly-scoped file passes"
fi

for f in docker-compose.yml docker-compose.dev.yml; do
  out=$(check_file "$f" 2>&1) || true
  if [[ -z "$out" ]]; then
    record yes "$f: docker-socket-proxy-write scope holds"
  else
    record no "$f: docker-socket-proxy-write scope holds"
    echo "$out" | sed 's/^/    /'
  fi
done

echo
echo "compose_docker_write_proxy_scope_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
