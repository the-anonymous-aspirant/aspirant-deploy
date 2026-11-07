#!/usr/bin/env bash
set -euo pipefail

# The shared .env reaches `server` only (system_3 #9313, which re-files #5286).
# .env holds JWT_SECRET, which signs aspirant-server's session tokens (the role
# claim rides in them), and BREAK_GLASS_TOKEN, which stands in for the
# Cloudflare Access assertion on the admin sign-in (#8798). `env_file: .env`
# hands a container every name in the file, so a service carrying it could
# forge an Admin session. Every other service lists the names it reads under
# `environment:`, interpolated from .env, and this test keeps it that way in
# every committed docker-compose*.yml.
#
# Usage: ./tests/compose_secret_scope_unit.sh

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

# check_file <path>: prints one line per offending service and exits non-zero
# when any service other than `server` carries an env_file or names a
# server-only secret in its environment (as a key or inside a ${...} value).
check_file() {
  python3 - "$1" <<'EOF'
import re
import sys
import yaml

SERVER_ONLY = ("JWT_SECRET", "BREAK_GLASS_TOKEN")
services = (yaml.safe_load(open(sys.argv[1])) or {}).get("services") or {}
bad = 0
for name, spec in services.items():
    if name == "server":
        continue
    spec = spec or {}
    if spec.get("env_file"):
        print(f"{name} has env_file")
        bad += 1
    env = spec.get("environment") or {}
    pairs = env.items() if isinstance(env, dict) else (
        (e.split("=", 1) + [""])[:2] for e in env)
    for key, value in pairs:
        for secret in SERVER_ONLY:
            if key == secret or re.search(r"\$\{?" + secret + r"\b", str(value or "")):
                print(f"{name} names {secret}")
                bad += 1
sys.exit(1 if bad else 0)
EOF
}

# Negative controls: each way a secret could reach a non-server service.
cat > "$TMPDIR_TEST/env_file.yml" <<'EOF'
services:
  server:
    env_file: [.env]
  browser:
    env_file: [.env]
EOF
cat > "$TMPDIR_TEST/key.yml" <<'EOF'
services:
  commander:
    environment:
      JWT_SECRET: "${JWT_SECRET}"
EOF
cat > "$TMPDIR_TEST/value.yml" <<'EOF'
services:
  advisor:
    environment:
      - "SIGNING_KEY=${BREAK_GLASS_TOKEN}"
EOF
cat > "$TMPDIR_TEST/server_only.yml" <<'EOF'
services:
  server:
    env_file: [.env]
    environment:
      JWT_SECRET: "${JWT_SECRET}"
  browser:
    environment:
      DB_PASSWORD: "${DB_PASSWORD}"
EOF
for bad in env_file key value; do
  if check_file "$TMPDIR_TEST/$bad.yml" >/dev/null; then
    record no "negative control ($bad): the check refuses it"
  else
    record yes "negative control ($bad): the check refuses it"
  fi
done
if check_file "$TMPDIR_TEST/server_only.yml" >/dev/null; then
  record yes "positive control: server alone may carry .env and JWT_SECRET"
else
  record no "positive control: server alone may carry .env and JWT_SECRET"
fi

for f in docker-compose*.yml; do
  if out="$(check_file "$f")"; then
    record yes "$f: only server receives the shared .env"
  else
    record no "$f: only server receives the shared .env"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
done

# The resolved configuration, as docker compose itself computes it, against a
# sentinel .env: no service but server holds the sentinel value of either
# secret. Skipped where docker compose is absent (the static check above still
# runs).
if docker compose version >/dev/null 2>&1; then
  mkdir -p "$TMPDIR_TEST/resolved"
  cp docker-compose.yml "$TMPDIR_TEST/resolved/"
  {
    grep -oE '\$\{[A-Z_][A-Z0-9_]*' docker-compose.yml | sed 's/^\${//' | sort -u \
      | grep -vx COMPOSE_PROJECT_NAME \
      | while read -r n; do echo "$n=sentinel-$n"; done
    echo "BREAK_GLASS_TOKEN=sentinel-BREAK_GLASS_TOKEN"
    echo "COMPOSE_PROJECT_NAME=secret-scope-test"
  } | sort -u > "$TMPDIR_TEST/resolved/.env"
  if docker compose --project-directory "$TMPDIR_TEST/resolved" config --format json \
      > "$TMPDIR_TEST/resolved.json" 2>"$TMPDIR_TEST/resolved.err"; then
    leaks="$(python3 - "$TMPDIR_TEST/resolved.json" <<'EOF'
import json
import sys

cfg = json.load(open(sys.argv[1]))
for name, spec in cfg["services"].items():
    if name == "server":
        continue
    for key, value in (spec.get("environment") or {}).items():
        if str(value) in ("sentinel-JWT_SECRET", "sentinel-BREAK_GLASS_TOKEN"):
            print(f"{name}:{key}")
EOF
)"
    server_has="$(python3 -c 'import json,sys; e=json.load(open(sys.argv[1]))["services"]["server"].get("environment") or {}; print(e.get("JWT_SECRET",""), e.get("BREAK_GLASS_TOKEN",""))' "$TMPDIR_TEST/resolved.json")"
    if [[ -z "$leaks" ]]; then
      record yes "resolved config: no service but server holds JWT_SECRET or BREAK_GLASS_TOKEN"
    else
      record no "resolved config: no service but server holds JWT_SECRET or BREAK_GLASS_TOKEN ($leaks)"
    fi
    if [[ "$server_has" == "sentinel-JWT_SECRET sentinel-BREAK_GLASS_TOKEN" ]]; then
      record yes "resolved config: server still receives both from .env"
    else
      record no "resolved config: server still receives both from .env"
    fi
  else
    record no "resolved config: docker compose config failed ($(head -1 "$TMPDIR_TEST/resolved.err"))"
  fi
else
  echo "  SKIP  resolved config: docker compose is not available"
fi

echo
echo "compose_secret_scope_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
