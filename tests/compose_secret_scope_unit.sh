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
    # system_3 #10680: the start/stop token reaches monitor as CONTROL_TOKEN
    # and server as MONITOR_CONTROL_TOKEN (its env_file), and no one else.
    control="$(python3 - "$TMPDIR_TEST/resolved.json" <<'EOF'
import json
import sys

cfg = json.load(open(sys.argv[1]))["services"]


def env(service):
    return cfg.get(service, {}).get("environment") or {}


holders = sorted(
    f"{name}:{key}"
    for name in cfg
    for key, value in env(name).items()
    if str(value) == "sentinel-MONITOR_CONTROL_TOKEN"
)
print(env("monitor").get("CONTROL_TOKEN", ""), env("server").get("MONITOR_CONTROL_TOKEN", ""), " ".join(holders))
EOF
)"
    want="sentinel-MONITOR_CONTROL_TOKEN sentinel-MONITOR_CONTROL_TOKEN monitor:CONTROL_TOKEN server:MONITOR_CONTROL_TOKEN"
    if [[ "$control" == "$want" ]]; then
      record yes "resolved config: the control token reaches monitor (CONTROL_TOKEN) and server (MONITOR_CONTROL_TOKEN) only"
    else
      record no "resolved config: the control token reaches monitor (CONTROL_TOKEN) and server (MONITOR_CONTROL_TOKEN) only (got: $control)"
    fi
  else
    record no "resolved config: docker compose config failed ($(head -1 "$TMPDIR_TEST/resolved.err"))"
  fi
else
  echo "  SKIP  resolved config: docker compose is not available"
fi

# --- Per-service database logins (system_3 #9317, #9320) --------------------
# transcriber, commander, advisor and browser each log in as their own role
# once cut over, and as the admin pair (DB_USER, a superuser) until then and
# after a rollback. The switch is per service and lives in .env:
#   ASPIRANT_<SVC>_DB_USER=aspirant_<svc>
#   ASPIRANT_<SVC>_DB_LOGIN_PASSWORD=${ASPIRANT_<SVC>_DB_PASSWORD}
# The default stays the admin pair on purpose: auto-pull.sh drives compose from
# this checkout, so a role default would start a service as its role before
# `db-roles.sh move` (its startup would create empty tables in its schema), or
# fail compose outright while the role passwords are unset.
DB_SERVICES="transcriber commander advisor browser"

# check_db_logins <path>: prints one line per offence, exits non-zero on any.
check_db_logins() {
  python3 - "$1" "$DB_SERVICES" <<'EOF'
import re
import sys
import yaml

services = (yaml.safe_load(open(sys.argv[1])) or {}).get("services") or {}
db_services = sys.argv[2].split()
admin_ok = {"server", "postgres", *db_services}
bad = 0
for name, spec in services.items():
    env = (spec or {}).get("environment") or {}
    pairs = dict(env.items() if isinstance(env, dict) else (
        (e.split("=", 1) + [""])[:2] for e in env))
    text = " ".join(f"{k}={v}" for k, v in pairs.items())
    if name in db_services:
        s = name.upper()
        want = {
            "DB_USER": "${ASPIRANT_%s_DB_USER:-${DB_USER}}" % s,
            "DB_PASSWORD": "${ASPIRANT_%s_DB_LOGIN_PASSWORD:-${DB_PASSWORD}}" % s,
        }
        for key, value in want.items():
            if str(pairs.get(key)) != value:
                print(f"{name}: {key} is {pairs.get(key)!r}, want {value!r}")
                bad += 1
        # The label a superuser fall-back is caught by (#10325): a literal, so a
        # lost .env switch cannot take the label with it.
        label = pairs.get("PGAPPNAME")
        if str(label) != f"aspirant-{name}" or "$" in str(label):
            print(f"{name}: PGAPPNAME is {label!r}, want the literal 'aspirant-{name}'")
            bad += 1
    elif name not in admin_ok and re.search(r"\$\{?DB_PASSWORD\b", text):
        print(f"{name} names the admin DB_PASSWORD")
        bad += 1
    for owner in re.findall(r"ASPIRANT_([A-Z]+)_DB_(?:USER|LOGIN_PASSWORD|PASSWORD)\b", text):
        if owner.lower() != name:
            print(f"{name} names {owner.lower()}'s database login")
            bad += 1
sys.exit(1 if bad else 0)
EOF
}

# Negative controls: a crossed login, a service left on the admin pair with no
# switch, and an unrelated service reaching for the admin password.
cat > "$TMPDIR_TEST/db_crossed.yml" <<'EOF'
services:
  transcriber:
    environment:
      DB_USER: "${ASPIRANT_TRANSCRIBER_DB_USER:-${DB_USER}}"
      DB_PASSWORD: "${ASPIRANT_COMMANDER_DB_LOGIN_PASSWORD:-${DB_PASSWORD}}"
EOF
cat > "$TMPDIR_TEST/db_admin_only.yml" <<'EOF'
services:
  advisor:
    environment:
      DB_USER: "${DB_USER}"
      DB_PASSWORD: "${DB_PASSWORD}"
EOF
cat > "$TMPDIR_TEST/db_other_service.yml" <<'EOF'
services:
  monitor:
    environment:
      - "PGPASSWORD=${DB_PASSWORD}"
EOF
# The label: interpolated from .env, and crossed (otherwise well-formed).
cat > "$TMPDIR_TEST/db_label_interpolated.yml" <<'EOF2'
services:
  transcriber:
    environment:
      DB_USER: "${ASPIRANT_TRANSCRIBER_DB_USER:-${DB_USER}}"
      DB_PASSWORD: "${ASPIRANT_TRANSCRIBER_DB_LOGIN_PASSWORD:-${DB_PASSWORD}}"
      PGAPPNAME: "${TRANSCRIBER_APPNAME:-aspirant-transcriber}"
EOF2
cat > "$TMPDIR_TEST/db_label_crossed.yml" <<'EOF2'
services:
  transcriber:
    environment:
      DB_USER: "${ASPIRANT_TRANSCRIBER_DB_USER:-${DB_USER}}"
      DB_PASSWORD: "${ASPIRANT_TRANSCRIBER_DB_LOGIN_PASSWORD:-${DB_PASSWORD}}"
      PGAPPNAME: aspirant-commander
EOF2
cat > "$TMPDIR_TEST/db_label_ok.yml" <<'EOF2'
services:
  transcriber:
    environment:
      DB_USER: "${ASPIRANT_TRANSCRIBER_DB_USER:-${DB_USER}}"
      DB_PASSWORD: "${ASPIRANT_TRANSCRIBER_DB_LOGIN_PASSWORD:-${DB_PASSWORD}}"
      PGAPPNAME: aspirant-transcriber
EOF2
if check_db_logins "$TMPDIR_TEST/db_label_ok.yml" >/dev/null; then
  record yes "positive control (db_label_ok): a literal own label passes"
else
  record no "positive control (db_label_ok): a literal own label passes"
fi
for bad in db_crossed db_admin_only db_other_service db_label_interpolated db_label_crossed; do
  if check_db_logins "$TMPDIR_TEST/$bad.yml" >/dev/null; then
    record no "negative control ($bad): the login check refuses it"
  else
    record yes "negative control ($bad): the login check refuses it"
  fi
done

for f in docker-compose*.yml; do
  if out="$(check_db_logins "$f")"; then
    record yes "$f: each DB service has its own login switch, and no other service names the admin password"
  else
    record no "$f: each DB service has its own login switch, and no other service names the admin password"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
done

# Resolved, three ways: no switch set (today), one switched, all switched.
# resolve_db <dir> <switched services...>: prints "svc user password" per DB
# service, from docker compose's own resolution against a sentinel .env.
resolve_db() {
  local dir="$1"; shift
  mkdir -p "$dir"
  cp docker-compose.yml "$dir/"
  {
    grep -oE '\$\{[A-Z_][A-Z0-9_]*' docker-compose.yml | sed 's/^\${//' | sort -u \
      | grep -vx COMPOSE_PROJECT_NAME \
      | grep -vE '^ASPIRANT_[A-Z]+_DB_(USER|LOGIN_PASSWORD)$' \
      | while read -r n; do echo "$n=sentinel-$n"; done
    for s in $DB_SERVICES; do
      echo "ASPIRANT_${s^^}_DB_PASSWORD=sentinel-role-$s"
    done
    echo "COMPOSE_PROJECT_NAME=secret-scope-test"
  } | sort -u > "$dir/.env"
  local s
  for s in "$@"; do
    printf 'ASPIRANT_%s_DB_USER=aspirant_%s\n' "${s^^}" "$s" >> "$dir/.env"
    printf 'ASPIRANT_%s_DB_LOGIN_PASSWORD=${ASPIRANT_%s_DB_PASSWORD}\n' "${s^^}" "${s^^}" >> "$dir/.env"
  done
  docker compose --project-directory "$dir" config --format json 2>"$dir/err" \
    | python3 -c '
import json, sys
cfg = json.load(sys.stdin)["services"]
for s in sys.argv[1].split():
    e = cfg[s].get("environment") or {}
    print(s, e.get("DB_USER"), e.get("DB_PASSWORD"))
' "$DB_SERVICES"
}

# expect_db <label> <resolved output> <switched services...>
expect_db() {
  local label="$1" got="$2"; shift 2
  local want="" s
  for s in $DB_SERVICES; do
    if [[ " $* " == *" $s "* ]]; then
      want+="$s aspirant_$s sentinel-role-$s"$'\n'
    else
      want+="$s sentinel-DB_USER sentinel-DB_PASSWORD"$'\n'
    fi
  done
  if [[ "$got"$'\n' == "$want" ]]; then
    record yes "$label"
  else
    record no "$label"
    diff <(printf '%s' "$want") <(printf '%s\n' "$got") | sed 's/^/        /' || true
  fi
}

if docker compose version >/dev/null 2>&1; then
  got="$(resolve_db "$TMPDIR_TEST/db_none")"
  expect_db "resolved: with no switch set, all four keep the admin pair (no change on merge)" "$got"
  got="$(resolve_db "$TMPDIR_TEST/db_one" commander)"
  expect_db "resolved: switching commander moves commander alone" "$got" commander
  # shellcheck disable=SC2086
  got="$(resolve_db "$TMPDIR_TEST/db_all" $DB_SERVICES)"
  # shellcheck disable=SC2086
  expect_db "resolved: all four switched, each holds only its own role password" "$got" $DB_SERVICES
  if [[ "$got" != *sentinel-DB_PASSWORD* ]]; then
    record yes "resolved: all four switched, none holds the admin DB_PASSWORD"
  else
    record no "resolved: all four switched, none holds the admin DB_PASSWORD"
  fi
  # The label resolves to its literal both before and after the switch: it is
  # what tells a fallen-back service apart from server's own superuser sessions.
  for state in db_none db_all; do
    labels="$(docker compose --project-directory "$TMPDIR_TEST/$state" config --format json 2>/dev/null \
      | python3 -c '
import json, sys
cfg = json.load(sys.stdin)["services"]
print(" ".join(str((cfg[s].get("environment") or {}).get("PGAPPNAME")) for s in sys.argv[1].split()))
' "$DB_SERVICES")"
    want="aspirant-transcriber aspirant-commander aspirant-advisor aspirant-browser"
    if [[ "$labels" == "$want" ]]; then
      record yes "resolved ($state): each DB service carries PGAPPNAME aspirant-<svc>"
    else
      record no "resolved ($state): each DB service carries PGAPPNAME aspirant-<svc> (got: $labels)"
    fi
  done
else
  echo "  SKIP  resolved DB logins: docker compose is not available"
fi

echo
echo "compose_secret_scope_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
