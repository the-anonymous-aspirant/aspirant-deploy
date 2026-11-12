#!/usr/bin/env bash
set -euo pipefail

# Provision the per-service database roles (system_3 #9317-A1, #9318).
#
# transcriber, commander, advisor and browser each get a login role,
# aspirant_<svc>, and a schema of the same name that heads its search_path, in
# place of the superuser they shared with server. server gets two roles
# (system_3 #9324-A1): aspirant_server_owner owns schema aspirant_server and
# its tables and runs AutoMigrate; aspirant_server, which the running server
# uses, has DML on them only. The SQL is
# scripts/db-roles.sql. This wrapper reads the role passwords from .env and
# hands them to psql inside the postgres container by NAME (`docker exec -e
# NAME`, read there with psql's \getenv), so no value appears on a command
# line, in `ps`, or in this script's output.
#
# Usage:
#   ./scripts/db-roles.sh                    provision: roles, schemas, grants.
#                                            Idempotent, safe at any time, and
#                                            never moves a table.
#   ./scripts/db-roles.sh move <svc>...      also move those services' tables
#                                            from public into their schemas
#   ./scripts/db-roles.sh unmove <svc>...    also move them back to public,
#                                            owned by the superuser (rollback)
#
# A service must be connecting as its own role (#9320) before its tables move,
# and as the superuser again before they move back: a superuser session only
# searches `public`. Stop server across its move and unmove (`docker compose
# stop server`, move, `up -d server`): neither identity can serve on the
# other's side of it. Move commander before transcriber; unmove transcriber
# before commander (commander reads voice_messages). The SQL refuses the
# wrong order, triggers or rules on service tables, and duplicate tables.
#
# Environment (tests only):
#   DB_ROLES_ENV_FILE    env file to read (default: .env)
#   DB_ROLES_CONTAINER   postgres container (default: compose service `postgres`)

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENV_FILE="${DB_ROLES_ENV_FILE:-.env}"
REQUIRED=(
  ASPIRANT_TRANSCRIBER_DB_PASSWORD
  ASPIRANT_COMMANDER_DB_PASSWORD
  ASPIRANT_ADVISOR_DB_PASSWORD
  ASPIRANT_BROWSER_DB_PASSWORD
  ASPIRANT_SERVER_DB_PASSWORD
  ASPIRANT_SERVER_OWNER_DB_PASSWORD
)
SERVICES=(transcriber commander advisor browser server)

mode="${1:-provision}"
[[ $# -gt 0 ]] && shift
case "$mode" in
  provision) [[ $# -eq 0 ]] || { echo "db-roles: provision takes no services" >&2; exit 2; } ;;
  move|unmove)
    [[ $# -gt 0 ]] || { echo "db-roles: $mode needs at least one of: ${SERVICES[*]}" >&2; exit 2; }
    for svc in "$@"; do
      [[ " ${SERVICES[*]} " == *" $svc "* ]] || { echo "db-roles: unknown service: $svc" >&2; exit 2; }
    done ;;
  *) echo "usage: $0 [move|unmove <service>...]" >&2; exit 2 ;;
esac

env_value() {  # env_value <name>: the last NAME=value in $ENV_FILE, quotes stripped
  local line
  line="$(grep -E "^$1=" "$ENV_FILE" | tail -n 1 || true)"
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

if [[ ! -r "$ENV_FILE" ]]; then
  echo "db-roles: cannot read $ENV_FILE" >&2
  exit 2
fi

missing=()
pass_env=()
for name in "${REQUIRED[@]}"; do
  value="$(env_value "$name")"
  if [[ -z "$value" ]]; then
    missing+=("$name")
  else
    export "$name=$value"
    pass_env+=(-e "$name")
  fi
done
if (( ${#missing[@]} )); then
  echo "db-roles: refusing to run, $ENV_FILE has no value for: ${missing[*]}" >&2
  echo "db-roles: generate each with: openssl rand -hex 32" >&2
  exit 2
fi
unset value
if [[ "$mode" != provision ]]; then
  list="$(IFS=,; echo "$*")"
  if [[ "$mode" == move ]]; then export DB_ROLES_MOVE="$list"; pass_env+=(-e DB_ROLES_MOVE); fi
  if [[ "$mode" == unmove ]]; then export DB_ROLES_UNMOVE="$list"; pass_env+=(-e DB_ROLES_UNMOVE); fi
fi

CONTAINER="${DB_ROLES_CONTAINER:-$(docker compose ps -q postgres)}"
if [[ -z "$CONTAINER" ]]; then
  echo "db-roles: the postgres service is not running" >&2
  exit 1
fi

docker exec -i "${pass_env[@]}" "$CONTAINER" \
  sh -c 'psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' \
  < scripts/db-roles.sql
