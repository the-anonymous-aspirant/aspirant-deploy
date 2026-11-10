#!/usr/bin/env bash
set -euo pipefail

# explorer-api has no auth of its own (system_3 #10353, security review
# #8813 D1): the gate is client-nginx's own auth_request in front of it.
# Before #8813 ever hands it a decryption key, it must sit on a network only
# client-nginx (and itself) can reach — not `default`, which 14 other
# containers share. This test keeps that true in every committed
# docker-compose*.yml: `explorer-api`'s networks are exactly
# {explorer_api, lake}, and no service other than client-blue/client-green
# joins `explorer_api`.
#
# Usage: ./tests/compose_network_scope_unit.sh

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
# of the two properties above do not hold. Services outside the explorer/
# client profiles (not present at all) are simply absent from the config and
# raise no violation — the check is about what IS rendered, not forcing
# every profile on.
check_file() {
  python3 - "$1" <<'EOF'
import sys
import yaml

services = (yaml.safe_load(open(sys.argv[1])) or {}).get("services") or {}
# "client" is docker-compose.dev.yml's single dev-mode client service,
# standing in for the blue/green pair production runs.
ALLOWED_EXPLORER_API_MEMBERS = {"explorer-api", "client-blue", "client-green", "client"}

def nets(spec):
    n = (spec or {}).get("networks")
    if n is None:
        return set()
    if isinstance(n, dict):
        return set(n.keys())
    return set(n)

bad = 0
api = services.get("explorer-api")
if api is not None:
    got = nets(api)
    if got != {"explorer_api", "lake"}:
        print(f"explorer-api networks are {sorted(got)}, want exactly "
              "{'explorer_api', 'lake'}")
        bad += 1

for name, spec in services.items():
    if name in ALLOWED_EXPLORER_API_MEMBERS:
        continue
    if "explorer_api" in nets(spec):
        print(f"{name} joins explorer_api, which only "
              f"{sorted(ALLOWED_EXPLORER_API_MEMBERS)} may")
        bad += 1

sys.exit(1 if bad else 0)
EOF
}

# Negative controls: each way the boundary could be violated.
cat > "$TMPDIR_TEST/still_default.yml" <<'EOF'
services:
  explorer-api:
    networks:
      - default
      - lake
EOF
cat > "$TMPDIR_TEST/missing_lake.yml" <<'EOF'
services:
  explorer-api:
    networks:
      - explorer_api
EOF
cat > "$TMPDIR_TEST/neighbour_joins.yml" <<'EOF'
services:
  explorer-api:
    networks:
      - explorer_api
      - lake
  browser:
    networks:
      - default
      - explorer_api
EOF
for bad in still_default missing_lake neighbour_joins; do
  if check_file "$TMPDIR_TEST/$bad.yml" >/dev/null; then
    record no "negative control ($bad): the check refuses it"
  else
    record yes "negative control ($bad): the check refuses it"
  fi
done

cat > "$TMPDIR_TEST/good.yml" <<'EOF'
services:
  explorer-api:
    networks:
      - explorer_api
      - lake
  client-blue:
    networks:
      - default
      - explorer_api
  client-green:
    networks:
      - default
      - explorer_api
  translator:
    networks:
      - default
EOF
if check_file "$TMPDIR_TEST/good.yml" >/dev/null; then
  record yes "positive control: the intended shape passes"
else
  record no "positive control: the intended shape passes"
fi

for f in docker-compose*.yml; do
  if out="$(check_file "$f")"; then
    record yes "$f: explorer-api's network scope holds"
  else
    record no "$f: explorer-api's network scope holds"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
done

# The resolved configuration, as docker compose itself computes it, with the
# explorer and client profiles enabled (the only way explorer-api renders at
# all). Skipped where docker compose is absent (the static check above still
# runs) or where the repo's own .env cannot be found.
if docker compose version >/dev/null 2>&1 && [[ -f .env ]]; then
  if out="$(COMPOSE_PROFILES=explorer,client docker compose config --format json 2>"$TMPDIR_TEST/resolved.err")"; then
    printf '%s' "$out" > "$TMPDIR_TEST/resolved.json"
    if check_file "$TMPDIR_TEST/resolved.json" >"$TMPDIR_TEST/resolved.out" 2>&1; then
      record yes "resolved config (explorer+client profiles): network scope holds"
    else
      record no "resolved config (explorer+client profiles): network scope holds"
      sed 's/^/        /' "$TMPDIR_TEST/resolved.out"
    fi
  else
    record no "resolved config: docker compose config failed ($(head -1 "$TMPDIR_TEST/resolved.err"))"
  fi
else
  echo "  SKIP  resolved config: docker compose or .env is not available"
fi

echo
echo "compose_network_scope_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
