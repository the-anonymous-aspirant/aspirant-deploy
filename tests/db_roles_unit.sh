#!/usr/bin/env bash
set -euo pipefail

# scripts/db-roles.sh (system_3 #9317-A1, #9318; design #9317 c57820).
#
# Part 1 runs anywhere: the script refuses bad input, naming the missing
# password names and printing no value, before it touches a database.
#
# Part 2 needs docker and the four service images. It boots a throwaway
# pgvector/pgvector:pg16 whose superuser is aspirant_admin, as on the cell, and
# runs each service's REAL startup database code from its own image:
#   - phase 1 as the superuser, as production does today, so the tables are
#     created in `public`, owned by the superuser;
#   - phase 2 as the service's own role, after `db-roles.sh` and
#     `db-roles.sh move`.
# Phase 2 must succeed and create no shadow table. Then it checks:
#   - every refusal, including the search_path attack security reproduced
#     (c57812), shown first to succeed under the grant c57806 proposed;
#   - the trigger refusal;
#   - rollback with `unmove`;
#   - idempotence.
# Running the images, not a model of them, is the point. It is how this test
# found that a no-op `CREATE INDEX IF NOT EXISTS` needs CREATE on the schema.
#
# Usage: ./tests/db_roles_unit.sh   (DB_ROLES_TEST_KEEP=1 keeps the container)

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
NET="db-roles-test-$$"
PG="db-roles-pg-$$"
cleanup() {
  if [[ -n "${DB_ROLES_TEST_KEEP:-}" ]]; then
    echo "kept: container $PG, network $NET, logs in $TMPDIR_TEST"
    return
  fi
  docker rm -f "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

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
yes_if() { if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }
finish() { echo; echo "db_roles_unit: $PASS passed, $FAIL failed"; [[ "$FAIL" -eq 0 ]]; exit; }

# --- Part 1: refusal ---------------------------------------------------------

printf 'ASPIRANT_TRANSCRIBER_DB_PASSWORD=value-that-must-not-print\n' > "$TMPDIR_TEST/partial.env"
rc=0
out="$(DB_ROLES_ENV_FILE="$TMPDIR_TEST/partial.env" DB_ROLES_CONTAINER=no-such-container \
  ./scripts/db-roles.sh 2>&1)" || rc=$?
record "$(yes_if test "$rc" -eq 2)" "refuses with exit 2 when a role password is missing"
record "$(yes_if grep -q ASPIRANT_BROWSER_DB_PASSWORD <<<"$out")" "names the missing password names"
record "$(yes_if bash -c '! grep -q value-that-must-not-print <<<"$1"' _ "$out")" "prints no password value"
rc=0
DB_ROLES_ENV_FILE="$TMPDIR_TEST/partial.env" ./scripts/db-roles.sh move penpot >/dev/null 2>&1 || rc=$?
record "$(yes_if test "$rc" -eq 2)" "refuses an unknown service name"

# --- Part 2: integration -----------------------------------------------------

IMAGE_PREFIX="ghcr.io/the-anonymous-aspirant/aspirant"
SERVICES=(transcriber commander advisor browser)
if ! docker version >/dev/null 2>&1; then
  echo "  SKIP  integration: docker is not available"; finish
fi
for svc in "${SERVICES[@]}"; do
  if ! docker image inspect "$IMAGE_PREFIX-$svc:latest" >/dev/null 2>&1; then
    echo "  SKIP  integration: image $IMAGE_PREFIX-$svc:latest is not present"; finish
  fi
done

DB=aspirant_online_db
ADMIN_PW="$(openssl rand -hex 16)"
declare -A ROLE_PW
for svc in "${SERVICES[@]}"; do ROLE_PW[$svc]="$(openssl rand -hex 16)"; done
SIGNAL_PW="$(openssl rand -hex 16)"

docker network create "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_USER=aspirant_admin -e POSTGRES_PASSWORD="$ADMIN_PW" -e POSTGRES_DB="$DB" \
  pgvector/pgvector:pg16 >/dev/null
for _ in $(seq 60); do
  docker exec "$PG" psql -U aspirant_admin -d "$DB" -Atc 'select 1' >/dev/null 2>&1 && break
  sleep 1
done

# psql_as <role> <sql>: run as <role> over the local socket (trust in the image).
psql_as() { docker exec -i "$PG" psql -X -q -v ON_ERROR_STOP=1 -U "$1" -d "$DB" -Atc "$2"; }
# refused <role> <sql>: the statement fails with a privilege error.
refused() {
  local err
  if err="$(psql_as "$1" "$2" 2>&1)"; then return 1; fi
  grep -qiE "permission denied|must be (superuser|owner)" <<<"$err"
}
is_super() { [[ "$(psql_as aspirant_admin "SELECT rolsuper FROM pg_roles WHERE rolname = '$1'")" == t ]]; }

# The cell's starting state: vector installed, a server table the services
# must never reach, and the system_3 signal reader as #6226 provisions it.
psql_as aspirant_admin "
  CREATE EXTENSION vector;
  CREATE TABLE users (id int PRIMARY KEY, email varchar);
  INSERT INTO users VALUES (1, 'Admin@Example.com');
  CREATE ROLE aspirant_signal_ro LOGIN PASSWORD '$SIGNAL_PW';
  GRANT USAGE ON SCHEMA public TO aspirant_signal_ro" >/dev/null

# Each service's startup database code, as its app/main.py lifespan runs it.
POLL='with m.engine.connect() as c:
    c.execute(text("SELECT id, transcription FROM voice_messages WHERE status = '"'"'completed'"'"' AND id NOT IN (SELECT voice_message_id FROM commander_processed)")).fetchall()'
declare -A STARTUP
STARTUP[transcriber]='import app.main as m
m.Base.metadata.create_all(bind=m.engine)'
STARTUP[commander]="import app.main as m
from sqlalchemy import text
m.ensure_database_identity(m.engine, m.DB_NAME)
m.Base.metadata.create_all(bind=m.engine)
m.ensure_owner_user_id_column(m.engine)
m.ensure_missed_expected_slots_column(m.engine)
m.ensure_ocr_used_column(m.engine)
m.ensure_no_text_subkind_column(m.engine)
$POLL"
STARTUP[advisor]='import app.main as m
m.ensure_pgvector()
m.Base.metadata.create_all(bind=m.engine)
m.seed_domains()'
STARTUP[browser]='import app.main as m
m.Base.metadata.create_all(bind=m.engine)
m.apply_startup_column_adds()
db = m.SessionLocal()
m.seed_baseline_flows(db, m.FLOWS_DIR)
m.reclassify_all_jobs(db)
db.close()'

# run_startup <svc> <db user> <db password> [extra python] [signal password]
run_startup() {
  local code="${STARTUP[$1]}"
  [[ -n "${4:-}" ]] && code="$code"$'\n'"$4"
  timeout 600 docker run --rm --network "$NET" --entrypoint python \
    -e DB_HOST="$PG" -e DB_PORT=5432 -e DB_NAME="$DB" -e DB_USER="$2" -e DB_PASSWORD="$3" \
    -e ASPIRANT_SIGNAL_RO_PASSWORD="${5:-}" \
    "$IMAGE_PREFIX-$1:latest" -c "$code" >"$TMPDIR_TEST/$1-$2.log" 2>&1
}
show_errors() { grep -iE "error|denied" "$1" | head -3 | sed 's/^/        /' || true; }

for svc in "${SERVICES[@]}"; do
  record "$(yes_if run_startup "$svc" aspirant_admin "$ADMIN_PW")" \
    "phase 1: $svc's startup runs as the superuser (today's production)"
done
psql_as aspirant_admin "GRANT SELECT ON processed_valuations TO aspirant_signal_ro" >/dev/null

{
  for svc in "${SERVICES[@]}"; do
    echo "ASPIRANT_${svc^^}_DB_PASSWORD=${ROLE_PW[$svc]}"
  done
} > "$TMPDIR_TEST/roles.env"
db_roles() { DB_ROLES_ENV_FILE="$TMPDIR_TEST/roles.env" DB_ROLES_CONTAINER="$PG" ./scripts/db-roles.sh "$@"; }
leaks_password() {
  local v
  for v in "${ROLE_PW[@]}"; do grep -qF "$v" <<<"$1" && return 0; done
  return 1
}
# where <table>: the schema(s) holding it, space-separated.
where() { psql_as aspirant_admin "SELECT string_agg(schemaname, ' ' ORDER BY schemaname) FROM pg_tables WHERE tablename = '$1'"; }
snapshot() {
  psql_as aspirant_admin "
    SELECT string_agg(x, E'\n' ORDER BY x) FROM (
      SELECT format('role %s super=%s login=%s createrole=%s createdb=%s', rolname, rolsuper,
                    rolcanlogin, rolcreaterole, rolcreatedb) FROM pg_roles WHERE rolname LIKE 'aspirant_%'
      UNION ALL SELECT format('setting %s %s', setrole::regrole, setconfig) FROM pg_db_role_setting
      UNION ALL SELECT format('rel %s.%s kind=%s owner=%s acl=%s', n.nspname, c.relname, c.relkind,
                              c.relowner::regrole, c.relacl)
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE c.relkind IN ('r', 'v') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      UNION ALL SELECT format('schema %s owner=%s acl=%s', nspname, nspowner::regrole, nspacl)
        FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema'
    ) s(x)"
}

declare -A SVC_OF=(
  [voice_messages]=transcriber
  [commander_tasks]=commander [commander_notes]=commander [commander_processed]=commander
  [processed_valuations]=commander [extraction_jobs]=commander [extraction_diagnostics]=commander
  [advisor_domains]=advisor [advisor_documents]=advisor [advisor_chunks]=advisor
  [browser_flows]=browser [browser_flow_runs]=browser [browser_flow_actions]=browser
  [browser_flow_outputs]=browser [jobs]=browser [address_geocache]=browser
)

# provision: roles and schemas, nothing moved.
out="$(db_roles 2>&1)" && rc=0 || rc=$?
record "$(yes_if test "$rc" -eq 0)" "provision runs against the phase-1 database"
[[ "$rc" -eq 0 ]] || printf '%s\n' "$out" | sed 's/^/        /'
record "$(yes_if bash -c '! leaks_password "$1"' _ "$out")" "provision prints no password value"
unmoved=yes
for t in "${!SVC_OF[@]}"; do [[ "$(where "$t")" == public ]] || unmoved=no; done
record "$(yes_if test "$unmoved" = yes)" "provision moves no table"
nonsuper=yes
for svc in "${SERVICES[@]}"; do is_super "aspirant_$svc" && nonsuper=no; done
record "$(yes_if test "$nonsuper" = yes)" "the four roles exist and none is a superuser"

# The attack security reproduced (c57812): a role that can create in `public`
# plants an overload, and a superuser's ordinary call runs it. First shown
# working under the grant c57806 proposed, so the refusals below mean something.
psql_as aspirant_admin "CREATE ROLE c57806_role LOGIN; GRANT CREATE ON SCHEMA public TO c57806_role" >/dev/null
psql_as c57806_role "CREATE FUNCTION public.lower(varchar) RETURNS text LANGUAGE plpgsql AS \$\$
  BEGIN EXECUTE 'ALTER ROLE c57806_role SUPERUSER'; RETURN pg_catalog.lower(\$1::text); END \$\$" >/dev/null
psql_as aspirant_admin "SELECT lower(email) FROM users" >/dev/null
record "$(yes_if is_super c57806_role)" "control: with CREATE on public, the planted overload makes its role superuser"
psql_as aspirant_admin "DROP FUNCTION public.lower(varchar); DROP OWNED BY c57806_role; DROP ROLE c57806_role" >/dev/null

# move: commander must go before transcriber.
rc=0; out="$(db_roles move transcriber 2>&1)" || rc=$?
record "$(yes_if grep -q "move commander before" <<<"$out")" "move refuses transcriber while commander is still in public"
out="$(db_roles move commander transcriber advisor browser 2>&1)" && rc=0 || rc=$?
record "$(yes_if test "$rc" -eq 0)" "move commander transcriber advisor browser"
[[ "$rc" -eq 0 ]] || printf '%s\n' "$out" | sed 's/^/        /'
wrong=""
for t in "${!SVC_OF[@]}"; do
  want="aspirant_${SVC_OF[$t]}"
  [[ "$(where "$t")" == "$want" ]] || wrong+=" $t:$(where "$t")"
  [[ "$(psql_as aspirant_admin "SELECT tableowner FROM pg_tables WHERE tablename = '$t'")" == "$want" ]] || wrong+=" $t:owner"
done
record "$(yes_if test -z "$wrong")" "each of the 16 tables is in its service's schema, owned by its role${wrong:+ (wrong:$wrong)}"
record "$(yes_if test "$(where users)" = public)" "server's users table stays in public"

for svc in "${SERVICES[@]}"; do
  record "$(yes_if run_startup "$svc" "aspirant_$svc" "${ROLE_PW[$svc]}")" \
    "phase 2: $svc's whole startup runs as aspirant_$svc"
  show_errors "$TMPDIR_TEST/$svc-aspirant_$svc.log"
done
shadows="$(psql_as aspirant_admin "SELECT string_agg(schemaname || '.' || tablename, ' ') FROM pg_tables
  WHERE tablename IN ($(printf "'%s'," "${!SVC_OF[@]}" | sed 's/,$//')) AND schemaname NOT LIKE 'aspirant\_%'")"
extra="$(psql_as aspirant_admin "SELECT count(*) FROM pg_tables WHERE schemaname LIKE 'aspirant\_%'")"
record "$(yes_if test -z "$shadows" -a "$extra" -eq 16)" "phase 2 created no shadow table${shadows:+ (found: $shadows)}"

for svc in "${SERVICES[@]}"; do
  r="aspirant_$svc"
  record "$(yes_if refused "$r" "SELECT * FROM public.users")" "$r is refused on server's users table"
  record "$(yes_if refused "$r" "COPY (SELECT 1) TO PROGRAM 'true'")" "$r is refused COPY ... TO PROGRAM"
  record "$(yes_if refused "$r" "CREATE ROLE intruder")" "$r is refused CREATE ROLE"
  record "$(yes_if refused "$r" "CREATE TABLE public.planted (i int)")" "$r cannot create a table in public"
  record "$(yes_if refused "$r" "CREATE FUNCTION public.lower(varchar) RETURNS text LANGUAGE sql AS 'select 1::text'")" \
    "$r cannot plant a function in public"
  # In its own schema it may create functions, but no superuser session searches there.
  psql_as "$r" "CREATE FUNCTION $r.lower(varchar) RETURNS text LANGUAGE plpgsql AS \$\$
    BEGIN EXECUTE 'ALTER ROLE $r SUPERUSER'; RETURN pg_catalog.lower(\$1::text); END \$\$" >/dev/null
  psql_as aspirant_admin "SELECT lower(email) FROM users" >/dev/null
  record "$(yes_if bash -c '! [[ "$(docker exec "$1" psql -U aspirant_admin -d "$2" -Atc "SELECT rolsuper FROM pg_roles WHERE rolname = '\''$3'\''")" == t ]]' _ "$PG" "$DB" "$r")" \
    "a function $r plants in its own schema never runs for the superuser"
  psql_as "$r" "DROP FUNCTION $r.lower(varchar)" >/dev/null
done
record "$(yes_if psql_as aspirant_commander "SELECT count(*) FROM voice_messages")" \
  "aspirant_commander reads voice_messages (its view over transcriber's table)"
record "$(yes_if refused aspirant_browser "SELECT count(*) FROM aspirant_transcriber.voice_messages")" \
  "aspirant_browser cannot read voice_messages"
landed="$(psql_as aspirant_browser "CREATE TABLE later_table (i int); SELECT schemaname FROM pg_tables WHERE tablename = 'later_table'; DROP TABLE later_table")"
record "$(yes_if test "$landed" = aspirant_browser)" "a table a role creates later lands in its own schema"
record "$(yes_if psql_as aspirant_signal_ro "SELECT count(*) FROM processed_valuations")" \
  "aspirant_signal_ro still reads processed_valuations, unqualified, after the move"
record "$(yes_if refused aspirant_signal_ro "SELECT * FROM public.users")" "aspirant_signal_ro is refused on users"

# Commander's own signal-role provisioning needs CREATEROLE. It is a no-op
# while ASPIRANT_SIGNAL_RO_PASSWORD is unset, as it is in prod; this pins why
# the name must stay unset for commander once it runs as its role.
run_startup commander aspirant_commander "${ROLE_PW[commander]}" "m.ensure_signal_reader_role(m.engine)" "$SIGNAL_PW" || true
record "$(yes_if grep -qi "permission denied" "$TMPDIR_TEST/commander-aspirant_commander.log")" \
  "with ASPIRANT_SIGNAL_RO_PASSWORD set, commander's role cannot provision the signal role"

# A trigger on a service table stops every mode.
psql_as aspirant_commander "
  CREATE FUNCTION aspirant_commander.noop() RETURNS trigger LANGUAGE plpgsql AS \$\$ BEGIN RETURN NEW; END \$\$;
  CREATE TRIGGER planted BEFORE INSERT ON commander_notes FOR EACH ROW EXECUTE FUNCTION aspirant_commander.noop()" >/dev/null
rc=0; out="$(db_roles 2>&1)" || rc=$?
record "$(yes_if grep -q "triggers or rules" <<<"$out")" "provision refuses while a service table carries a trigger"
rc=0; out="$(db_roles unmove transcriber commander 2>&1)" || rc=$?
record "$(yes_if grep -q "triggers or rules" <<<"$out")" "unmove refuses while a service table carries a trigger"
psql_as aspirant_commander "DROP TRIGGER planted ON commander_notes; DROP FUNCTION aspirant_commander.noop()" >/dev/null

# Code attached without a trigger (security, c57836): a function in a service
# schema, called from a column default, would run as the superuser after a
# rollback. Every mode refuses while the function exists, and names it.
psql_as aspirant_browser "
  CREATE FUNCTION aspirant_browser.planted_default() RETURNS text LANGUAGE sql AS 'select 1::text';
  ALTER TABLE jobs ADD COLUMN planted text DEFAULT aspirant_browser.planted_default()" >/dev/null
for mode in "" "move browser" "unmove browser"; do
  rc=0; out="$(db_roles $mode 2>&1)" || rc=$?
  record "$(yes_if grep -q "functions or operators: aspirant_browser.planted_default" <<<"$out")" \
    "${mode:-provision} refuses while a service schema holds a function (a column default calls it)"
done
psql_as aspirant_browser "ALTER TABLE jobs DROP COLUMN planted; DROP FUNCTION aspirant_browser.planted_default()" >/dev/null
# An RLS policy on transcriber's table would run in commander's sessions.
psql_as aspirant_transcriber "ALTER TABLE voice_messages ENABLE ROW LEVEL SECURITY;
  CREATE POLICY planted ON voice_messages USING (true)" >/dev/null
for mode in "" "unmove transcriber"; do
  rc=0; out="$(db_roles $mode 2>&1)" || rc=$?
  record "$(yes_if grep -q "row-level security: aspirant_transcriber.voice_messages" <<<"$out")" \
    "${mode:-provision} refuses while a service table carries row-level security"
done
psql_as aspirant_transcriber "DROP POLICY planted ON voice_messages; ALTER TABLE voice_messages DISABLE ROW LEVEL SECURITY" >/dev/null

# Rollback: transcriber back on the superuser.
rc=0; out="$(db_roles unmove commander 2>&1)" || rc=$?
record "$(yes_if grep -q "unmove transcriber before" <<<"$out")" "unmove refuses commander while transcriber is still moved"
out="$(db_roles unmove transcriber 2>&1)" && rc=0 || rc=$?
record "$(yes_if test "$rc" -eq 0 -a "$(where voice_messages)" = public)" "unmove transcriber puts voice_messages back in public"
record "$(yes_if test "$(psql_as aspirant_admin "SELECT tableowner FROM pg_tables WHERE tablename = 'voice_messages'")" = aspirant_admin)" \
  "unmove gives the table back to the superuser"
record "$(yes_if run_startup transcriber aspirant_admin "$ADMIN_PW")" "after unmove, transcriber's startup runs as the superuser again"
record "$(yes_if test "$(where voice_messages)" = public)" "after unmove, no shadow voice_messages"
record "$(yes_if run_startup commander aspirant_commander "${ROLE_PW[commander]}")" \
  "commander, still on its role, reads voice_messages from public after transcriber's rollback"
out="$(db_roles move transcriber 2>&1)" && rc=0 || rc=$?
record "$(yes_if test "$rc" -eq 0 -a "$(where voice_messages)" = aspirant_transcriber)" "transcriber moves again"

before="$(snapshot)"
out="$(db_roles 2>&1)" && rc=0 || rc=$?
after="$(snapshot)"
record "$(yes_if test "$rc" -eq 0 -a "$before" = "$after")" "a further provision run changes no role, setting, owner, ACL or schema"
[[ "$before" == "$after" ]] || diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | sed 's/^/        /'
out="$(db_roles move commander transcriber advisor browser 2>&1)" && rc=0 || rc=$?
record "$(yes_if test "$rc" -eq 0 -a "$(snapshot)" = "$after")" "moving already-moved services is a no-op"

finish
