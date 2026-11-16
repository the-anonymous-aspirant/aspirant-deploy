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
# The Cloudflare Tunnel connector likewise (system_3 #10829-A1, security
# c69867): a remotely managed tunnel's ingress lives in the dashboard, so it
# may only ever reach the live client. `cloudflared`'s networks are exactly
# {tunnel}; only cloudflared and a client slot join `tunnel`; and the
# `client-active` alias sits on `tunnel` alone, on a client slot alone.
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

# The tunnel (#10829-A1, security c69867).
ALLOWED_TUNNEL_MEMBERS = {"cloudflared", "client-blue", "client-green"}
cf = services.get("cloudflared")
if cf is not None and nets(cf) != {"tunnel"}:
    print(f"cloudflared networks are {sorted(nets(cf))}, want exactly ['tunnel']")
    bad += 1
for name, spec in services.items():
    if "tunnel" in nets(spec) and name not in ALLOWED_TUNNEL_MEMBERS:
        print(f"{name} joins tunnel, which only {sorted(ALLOWED_TUNNEL_MEMBERS)} may")
        bad += 1
    n = (spec or {}).get("networks")
    if isinstance(n, dict):
        for net, cfg in n.items():
            if "client-active" in ((cfg or {}).get("aliases") or []):
                if net != "tunnel":
                    print(f"{name} carries client-active on {net}, not tunnel")
                    bad += 1
                if name not in {"client-blue", "client-green"}:
                    print(f"{name} carries client-active, which only a client slot may")
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
# The tunnel's ways to break (#10829-A1, security c69867).
cat > "$TMPDIR_TEST/cf_on_default.yml" <<'EOF'
services:
  cloudflared:
    networks:
      - default
EOF
cat > "$TMPDIR_TEST/cf_dual_homed.yml" <<'EOF'
services:
  cloudflared:
    networks:
      - tunnel
      - default
EOF
cat > "$TMPDIR_TEST/postgres_joins_tunnel.yml" <<'EOF'
services:
  cloudflared:
    networks:
      - tunnel
  postgres:
    networks:
      - default
      - tunnel
EOF
cat > "$TMPDIR_TEST/alias_on_default.yml" <<'EOF'
services:
  client-green:
    networks:
      default:
        aliases:
          - client-active
EOF
cat > "$TMPDIR_TEST/alias_on_server.yml" <<'EOF'
services:
  server:
    networks:
      tunnel:
        aliases:
          - client-active
EOF
for bad in still_default missing_lake neighbour_joins cf_on_default cf_dual_homed postgres_joins_tunnel alias_on_default alias_on_server; do
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
  cloudflared:
    networks:
      - tunnel
EOF
# The live slot as write_override merges it: base networks plus the alias.
cat > "$TMPDIR_TEST/good_live_slot.yml" <<'EOF'
services:
  cloudflared:
    networks:
      - tunnel
  client-green:
    networks:
      default: null
      explorer_api: null
      tunnel:
        aliases:
          - client-active
EOF
if check_file "$TMPDIR_TEST/good_live_slot.yml" >/dev/null; then
  record yes "positive control: the live slot on tunnel with client-active passes"
else
  record no "positive control: the live slot on tunnel with client-active passes"
fi
if check_file "$TMPDIR_TEST/good.yml" >/dev/null; then
  record yes "positive control: the intended shape passes"
else
  record no "positive control: the intended shape passes"
fi

for f in docker-compose*.yml; do
  if out="$(check_file "$f")"; then
    record yes "$f: network scope holds (explorer_api, tunnel)"
  else
    record no "$f: network scope holds (explorer_api, tunnel)"
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

# The tunnel as it actually merges (#10829-A1): the base file, the override
# write_override really writes, and the tunnel profile, rendered by docker
# compose itself. It needs no real .env: every ${VAR} gets a dummy value in a
# scratch project directory, and the token secret points at a scratch file, so
# this runs anywhere docker compose does. Nothing is started.
if docker compose version >/dev/null 2>&1; then
  PROJ="$TMPDIR_TEST/proj"; mkdir -p "$PROJ"
  grep -ohE '\$\{[A-Z0-9_]+' docker-compose.yml | sort -u | sed 's/^\${//; s/$/=dummy/' > "$PROJ/.env"
  printf 'not-a-token' > "$TMPDIR_TEST/token"
  printf 'secrets:\n  cloudflared_token:\n    file: %s\n' "$TMPDIR_TEST/token" > "$TMPDIR_TEST/secret.yml"
  ASPIRANT_DEPLOY_CLIENT_LIB=1 bash -c 'source scripts/deploy-client.sh; write_override green "$1"' _ "$TMPDIR_TEST/override.yml"
  if docker compose -p netscope --project-directory "$PROJ" -f "$PWD/docker-compose.yml" -f "$TMPDIR_TEST/override.yml" \
      -f "$TMPDIR_TEST/secret.yml" --profile tunnel config --format json > "$TMPDIR_TEST/merged.json" 2>"$TMPDIR_TEST/merged.err"; then
    if check_file "$TMPDIR_TEST/merged.json" >"$TMPDIR_TEST/merged.out" 2>&1; then
      record yes "merged config (base + write_override + tunnel profile): tunnel scope holds"
    else
      record no "merged config (base + write_override + tunnel profile): tunnel scope holds"
      sed 's/^/        /' "$TMPDIR_TEST/merged.out"
    fi
    # check_file cannot fail on what is absent, so assert presence too: the
    # live slot really is on tunnel with the alias, and keeps its base networks.
    if python3 - "$TMPDIR_TEST/merged.json" <<'EOF'
import json, sys
s = json.load(open(sys.argv[1]))["services"]
g = s["client-green"]["networks"]
ok = (set(g) == {"default", "explorer_api", "tunnel"}
      and "client-active" in ((g["tunnel"] or {}).get("aliases") or [])
      and "tunnel" not in (s["client-blue"].get("networks") or {})
      and set(s["cloudflared"]["networks"]) == {"tunnel"})
sys.exit(0 if ok else 1)
EOF
    then
      record yes "merged config: the live slot is on default, explorer_api and tunnel (alias client-active); the standby is not on tunnel"
    else
      record no "merged config: the live slot is on default, explorer_api and tunnel (alias client-active); the standby is not on tunnel"
    fi
  else
    record no "merged config: docker compose config failed ($(head -1 "$TMPDIR_TEST/merged.err"))"
  fi
else
  echo "  SKIP  merged tunnel config: docker compose is not available"
fi

echo
echo "compose_network_scope_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
