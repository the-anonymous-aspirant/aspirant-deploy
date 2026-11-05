#!/usr/bin/env bash
#
# A disposable end-to-end stack for the invoicing app (system_3 #9980, from the
# security ruling on #9979). The fleet's test logins live here, never on the
# served app.
#
#   e2e-stack.sh up              start a stack of the SERVED revisions with
#                                synthetic data and three fresh logins
#   e2e-stack.sh down <run-id>   remove everything that run created (idempotent)
#   e2e-stack.sh status          list runs and their containers
#
# What makes it safe (each rule is checked by tests/e2e_stack_unit.sh):
#   1. Isolation: its own network, the only published port on 127.0.0.1;
#      never aspirant-online_default, never .env, never a prod volume.
#   2. Synthetic data only: scripts/e2e_stack_seed.py writes invented records
#      through the server's own API. Nothing is read from aspirant_db.
#   3. Per-run secrets from a CSPRNG, written to 0600 files under the run's
#      directory and handed to containers with --env-file. They never appear
#      on argv, stdout or a log; `down` deletes them.
#   4. Both sides of the access gate: vinoly (owner, Member), e2e_admin
#      (Admin) and e2e_member (Member, not the owner).
#   5. The served containers are only inspected for their revision and image
#      ID. Their environment (JWT_SECRET) is never read.
#
# "Served" means the images the live containers run, pinned by image ID, so a
# pull of :latest during a run cannot change what is under test.

set -euo pipefail

ROOT="${E2E_STACK_ROOT:-${TMPDIR:-/tmp}/e2e-stack}"
LABEL="org.aspirant.e2e-stack.run"
SERVED_SERVER="${E2E_SERVED_SERVER:-aspirant-online-server-1}"
PORT_LO=18900
PORT_HI=18999
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { echo "e2e-stack: $*" >&2; exit 1; }

served_client() {
  docker ps --filter "name=aspirant-online-client" --filter "status=running" --format '{{.Names}}' | head -n 1
}

image_of() { docker inspect -f '{{.Image}}' "$1"; }
revision_of() { docker inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$1"; }

free_port() {
  local p
  for ((p = PORT_LO; p <= PORT_HI; p++)); do
    if ! ss -ltnH "sport = :$p" 2>/dev/null | grep -q .; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# CSPRNG secret, hex (safe in env files and SQL literals).
secret() { openssl rand -hex "${1:-24}"; }

cmd_up() {
  local client run dir port
  client="$(served_client)"
  [ -n "$client" ] || die "no running aspirant-online-client container to read the served revision from"
  docker inspect -f '{{.Id}}' "$SERVED_SERVER" >/dev/null 2>&1 || die "no $SERVED_SERVER container to read the served revision from"

  local server_img client_img server_rev client_rev
  server_img="$(image_of "$SERVED_SERVER")"
  client_img="$(image_of "$client")"
  server_rev="$(revision_of "$SERVED_SERVER")"
  client_rev="$(revision_of "$client")"

  run="$(date -u +%Y%m%d%H%M%S)-$(openssl rand -hex 2)"
  dir="$ROOT/$run"
  port="$(free_port)" || die "no free loopback port in $PORT_LO-$PORT_HI"

  # A failed up removes what it created: nothing half-built is left behind.
  UP_RUN="$run"
  UP_DONE=0
  trap 'if [ "${UP_DONE:-1}" != 1 ]; then echo "e2e-stack: up failed; removing run $UP_RUN" >&2; cmd_down "$UP_RUN" >/dev/null 2>&1 || true; fi' EXIT

  # The state root must be the caller's own directory, never a symlink
  # (a planted one under a shared /tmp would redirect the secrets).
  if [ -L "$ROOT" ]; then die "$ROOT is a symlink; set E2E_STACK_ROOT to your own directory"; fi
  if [ -e "$ROOT" ] && [ "$(stat -c %u "$ROOT")" != "$(id -u)" ]; then die "$ROOT is not owned by you; set E2E_STACK_ROOT to your own directory"; fi

  umask 077
  mkdir -p "$dir"
  chmod 700 "$ROOT" "$dir"

  local dbpw jwt
  dbpw="$(secret 16)"
  jwt="$(secret 32)"
  printf 'POSTGRES_USER=aspirant\nPOSTGRES_DB=aspirant_db\nPOSTGRES_PASSWORD=%s\n' "$dbpw" >"$dir/db.env"
  # CORS: the server rejects a cross-origin request whose Origin is not on its
  # allowlist (server/cors.go, default https://the-aspirant.com), and a
  # browser on this stack sends Origin http://127.0.0.1:<port>. This run's own
  # loopback origin is the only one allowed here; the served app is untouched.
  printf 'GIN_MODE=release\nDB_HOST=db\nDB_PORT=5432\nDB_USER=aspirant\nDB_NAME=aspirant_db\nDB_PASSWORD=%s\nJWT_SECRET=%s\nASSET_BASE_PATH=/data/assets\nCORS_ALLOWED_ORIGINS=http://127.0.0.1:%s\n' "$dbpw" "$jwt" "$port" >"$dir/server.env"
  printf 'E2E_URL=http://127.0.0.1:%s\nE2E_OWNER=vinoly\nE2E_OWNER_PASSWORD=%s\nE2E_ADMIN=e2e_admin\nE2E_ADMIN_PASSWORD=%s\nE2E_MEMBER=e2e_member\nE2E_MEMBER_PASSWORD=%s\n' \
    "$port" "$(secret 12)" "$(secret 12)" "$(secret 12)" >"$dir/run.env"
  chmod 600 "$dir"/*.env
  printf '%s\n' "$run" >"$dir/run-id"
  printf 'server=%s %s\nclient=%s %s\nport=%s\n' "$server_rev" "$server_img" "$client_rev" "$client_img" "$port" >"$dir/revisions"

  local net="s3e2e-$run"
  docker network create --label "$LABEL=$run" "$net" >/dev/null
  docker volume create --label "$LABEL=$run" "$net-db" >/dev/null

  docker run -d --name "$net-db" --label "$LABEL=$run" --network "$net" --network-alias db \
    --env-file "$dir/db.env" -v "$net-db:/var/lib/postgresql/data" postgres:16-alpine >/dev/null
  # Probe over TCP: on first boot the image runs initdb against a temporary
  # server that listens on the socket only, then restarts. A socket probe can
  # pass during that window and the next statement hit the restart.
  local ready=0
  for _ in $(seq 1 90); do
    if docker exec "$net-db" pg_isready -h 127.0.0.1 -U aspirant -d aspirant_db >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || die "scratch postgres did not become ready (run $run)"

  docker run -d --name "$net-server" --label "$LABEL=$run" --network "$net" --network-alias server \
    --tmpfs /data:mode=1777 --env-file "$dir/server.env" "$server_img" >/dev/null

  # Healthy from INSIDE the server container: nothing is published yet, so no
  # one on the host can reach POST /bootstrap/admin, which is open while the
  # users table is empty (security review on #10015).
  local healthy=0
  for _ in $(seq 1 90); do
    if docker exec "$net-server" wget -qO- http://127.0.0.1:8080/health >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 1
  done
  [ "$healthy" = 1 ] || die "scratch server did not become healthy (run $run)"

  # Logins: bcrypt in the scratch DB. The SQL travels on stdin from a
  # builtin printf, so no password is ever on an argv.
  # shellcheck disable=SC1091
  . "$dir/run.env"
  {
    printf 'create extension if not exists pgcrypto;\n'
    printf "insert into users (created_at, updated_at, username, email, password, role_id, session_epoch, email_verified_at) values\n"
    printf "(now(), now(), '%s', '%s@e2e.invalid', crypt('%s', gen_salt('bf', 10)), (select id from roles where role_name='Member'), 0, now()),\n" "$E2E_OWNER" "$E2E_OWNER" "$E2E_OWNER_PASSWORD"
    printf "(now(), now(), '%s', '%s@e2e.invalid', crypt('%s', gen_salt('bf', 10)), (select id from roles where role_name='Admin'), 0, now()),\n" "$E2E_ADMIN" "$E2E_ADMIN" "$E2E_ADMIN_PASSWORD"
    printf "(now(), now(), '%s', '%s@e2e.invalid', crypt('%s', gen_salt('bf', 10)), (select id from roles where role_name='Member'), 0, now());\n" "$E2E_MEMBER" "$E2E_MEMBER" "$E2E_MEMBER_PASSWORD"
  } | docker exec -i "$net-db" psql -q -v ON_ERROR_STOP=1 -U aspirant -d aspirant_db >/dev/null
  # Exactly our three: anything else means someone else wrote a user.
  local users
  users="$(printf 'select count(*) from users;\n' | docker exec -i "$net-db" psql -qAt -U aspirant -d aspirant_db)"
  [ "$users" = 3 ] || die "expected 3 users on the scratch DB, found $users (run $run)"

  # Only now publish the client edge.
  docker run -d --name "$net-client" --label "$LABEL=$run" --network "$net" \
    -p "127.0.0.1:$port:80" "$client_img" >/dev/null
  for _ in $(seq 1 90); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/health" || true)" = 200 ] && break
    sleep 1
  done
  [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/api/health" || true)" = 200 ] ||
    die "server not healthy through the client edge (run $run)"

  python3 -I "$HERE/e2e_stack_seed.py" "$dir/run.env"

  echo "login: $E2E_URL/login"
  echo "users: $E2E_OWNER (owner, Member), $E2E_ADMIN (Admin), $E2E_MEMBER (Member, not the owner)"
  echo "passwords: $dir/run.env (0600; removed by down)"
  echo "e2e-stack run: $run server=$server_rev client=$client_rev"
  UP_DONE=1
}

cmd_down() {
  local run="${1:-}"
  [ -n "$run" ] || die "usage: e2e-stack.sh down <run-id>"
  case "$run" in *[!0-9a-f-]*) die "not a run id: $run" ;; esac
  local ids
  ids="$(docker ps -aq --filter "label=$LABEL=$run")"
  [ -z "$ids" ] || docker rm -f $ids >/dev/null
  docker network ls -q --filter "label=$LABEL=$run" | while read -r n; do docker network rm "$n" >/dev/null; done
  docker volume ls -q --filter "label=$LABEL=$run" | while read -r v; do docker volume rm "$v" >/dev/null; done
  rm -rf "${ROOT:?}/$run"
  echo "e2e-stack: run $run removed"
}

cmd_status() {
  docker ps -a --filter "label=$LABEL" --format "{{.Label \"$LABEL\"}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
}

case "${1:-}" in
  up) cmd_up ;;
  down) shift; cmd_down "${1:-}" ;;
  status) cmd_status ;;
  *) echo "usage: e2e-stack.sh up | down <run-id> | status" >&2; exit 2 ;;
esac
