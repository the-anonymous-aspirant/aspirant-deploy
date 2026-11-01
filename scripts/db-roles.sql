-- Per-service database roles for transcriber, commander, advisor and browser
-- (system_3 #9317-A1, #9318; design #9317 c57820, after security's c57812).
-- Run by scripts/db-roles.sh as the superuser, which says how the inputs
-- arrive. Every run is idempotent.
--
-- Each service gets a login role, aspirant_<svc>, and a schema of the same
-- name that it owns and that heads its search_path. `move` puts the service's
-- tables into that schema; `unmove` puts them back in `public`. No role can
-- create anything in `public`: a role that could plant a function or operator
-- there would have a superuser session (server, backups, an operator's psql)
-- resolve to it (the CVE-2018-1058 search_path class). Owning a table that
-- stays in `public` is not enough either, because CREATE INDEX needs CREATE on
-- the table's schema even when the index exists; hence the move.
--
-- Inputs (psql variables read from the environment with \getenv):
--   pw_<svc>       the four role passwords
--   move_list      comma-separated services whose tables move to their schema
--   unmove_list    comma-separated services whose tables move back to public

\set ON_ERROR_STOP on
\getenv pw_transcriber ASPIRANT_TRANSCRIBER_DB_PASSWORD
\getenv pw_commander ASPIRANT_COMMANDER_DB_PASSWORD
\getenv pw_advisor ASPIRANT_ADVISOR_DB_PASSWORD
\getenv pw_browser ASPIRANT_BROWSER_DB_PASSWORD
\getenv move_list DB_ROLES_MOVE
\getenv unmove_list DB_ROLES_UNMOVE
\if :{?move_list}
\else
\set move_list ''
\endif
\if :{?unmove_list}
\else
\set unmove_list ''
\endif

-- The session resolves nothing a service role could have planted, and the
-- password statements are kept out of the server log whatever its setting.
SET search_path = pg_catalog, pg_temp;
SET log_statement = 'none';
SET log_min_error_statement = panic;

BEGIN;

-- Session-scoped (psql -f - is one session); a temp view depends on these.
CREATE TEMP TABLE service_tables (svc text, tbl name);
INSERT INTO pg_temp.service_tables VALUES
  ('transcriber', 'voice_messages'),
  ('commander', 'commander_tasks'),
  ('commander', 'commander_notes'),
  ('commander', 'commander_processed'),
  ('commander', 'processed_valuations'),
  ('commander', 'extraction_jobs'),
  ('commander', 'extraction_diagnostics'),
  ('advisor', 'advisor_domains'),
  ('advisor', 'advisor_documents'),
  ('advisor', 'advisor_chunks'),
  ('browser', 'browser_flows'),
  ('browser', 'browser_flow_runs'),
  ('browser', 'browser_flow_actions'),
  ('browser', 'browser_flow_outputs'),
  ('browser', 'jobs'),
  ('browser', 'address_geocache');

CREATE TEMP TABLE request (op text, svc text);
INSERT INTO pg_temp.request
  SELECT 'move', btrim(s) FROM unnest(string_to_array(:'move_list', ',')) AS s WHERE btrim(s) <> ''
  UNION ALL
  SELECT 'unmove', btrim(s) FROM unnest(string_to_array(:'unmove_list', ',')) AS s WHERE btrim(s) <> '';

-- Where each service table is now: 'public', 'own', or absent.
CREATE TEMP VIEW located AS
  SELECT s.svc, s.tbl, n.nspname AS schema,
         CASE n.nspname WHEN 'public' THEN 'public' ELSE 'own' END AS place
    FROM pg_temp.service_tables s
    JOIN pg_catalog.pg_class c ON c.relname = s.tbl AND c.relkind IN ('r', 'p')
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                                  AND n.nspname IN ('public', 'aspirant_' || s.svc);

DO $$
DECLARE
  bad text;
BEGIN
  SELECT string_agg(DISTINCT r.svc, ', ') INTO bad
    FROM pg_temp.request r
   WHERE r.svc NOT IN (SELECT svc FROM pg_temp.service_tables);
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'db-roles: unknown service(s): %', bad;
  END IF;

  -- A trigger or rule on a service table runs as whoever writes to it: after a
  -- rollback to the superuser, that would be the superuser.
  SELECT string_agg(format('%I.%I', l.schema, l.tbl), ', ') INTO bad
    FROM pg_temp.located l
    JOIN pg_catalog.pg_class c ON c.relname = l.tbl
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace AND n.nspname = l.schema
   WHERE EXISTS (SELECT 1 FROM pg_catalog.pg_trigger t WHERE t.tgrelid = c.oid AND NOT t.tgisinternal)
      OR EXISTS (SELECT 1 FROM pg_catalog.pg_rewrite w WHERE w.ev_class = c.oid AND w.rulename <> '_RETURN');
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'db-roles: refusing, service tables carry triggers or rules: %', bad;
  END IF;

  -- The same goes for code a table's owner can attach without a trigger: a
  -- column default, CHECK, generated column, expression index, domain
  -- constraint or RLS policy that calls a function. The roles can create code
  -- only in their own schemas (no CREATE anywhere else), and none of the four
  -- services creates any, so a function or operator there is refused
  -- outright, whatever might call it (security, c57836 on #9318).
  SELECT string_agg(format('%I.%I', n.nspname, x.name), ', ') INTO bad
    FROM (SELECT pronamespace AS nsp, proname AS name FROM pg_catalog.pg_proc
          UNION ALL SELECT oprnamespace, oprname FROM pg_catalog.pg_operator) x
    JOIN pg_catalog.pg_namespace n ON n.oid = x.nsp
   WHERE n.nspname IN (SELECT 'aspirant_' || svc FROM pg_temp.service_tables);
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'db-roles: refusing, service schemas contain functions or operators: %', bad;
  END IF;
  SELECT string_agg(format('%I.%I', l.schema, l.tbl), ', ') INTO bad
    FROM pg_temp.located l
    JOIN pg_catalog.pg_class c ON c.relname = l.tbl
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace AND n.nspname = l.schema
   WHERE c.relrowsecurity
      OR EXISTS (SELECT 1 FROM pg_catalog.pg_policy p WHERE p.polrelid = c.oid);
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'db-roles: refusing, service tables carry row-level security: %', bad;
  END IF;

  -- A table in both places means a service ran create_all where it could not
  -- see its own table. Stop rather than guess which copy holds the data.
  SELECT string_agg(tbl, ', ') INTO bad
    FROM (SELECT tbl FROM pg_temp.located GROUP BY tbl HAVING count(*) > 1) d;
  IF bad IS NOT NULL THEN
    RAISE EXCEPTION 'db-roles: refusing, tables exist in both public and the service schema: %', bad;
  END IF;

  -- Commander reads voice_messages. A commander still on the superuser has
  -- only `public` on its path, so transcriber's tables may leave `public` only
  -- once commander's have, and commander's may return only once transcriber's
  -- have.
  IF EXISTS (SELECT 1 FROM pg_temp.request WHERE op = 'move' AND svc = 'transcriber')
     AND NOT EXISTS (SELECT 1 FROM pg_temp.request WHERE op = 'move' AND svc = 'commander')
     AND EXISTS (SELECT 1 FROM pg_temp.located WHERE svc = 'commander' AND place = 'public') THEN
    RAISE EXCEPTION 'db-roles: move commander before (or with) transcriber: commander reads voice_messages';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_temp.request WHERE op = 'unmove' AND svc = 'commander')
     AND NOT EXISTS (SELECT 1 FROM pg_temp.request WHERE op = 'unmove' AND svc = 'transcriber')
     AND EXISTS (SELECT 1 FROM pg_temp.located WHERE svc = 'transcriber' AND place = 'own') THEN
    RAISE EXCEPTION 'db-roles: unmove transcriber before (or with) commander: commander reads voice_messages';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_temp.request m JOIN pg_temp.request u ON u.svc = m.svc
              WHERE m.op = 'move' AND u.op = 'unmove') THEN
    RAISE EXCEPTION 'db-roles: a service cannot be moved and unmoved in one run';
  END IF;
END $$;

-- advisor runs CREATE EXTENSION IF NOT EXISTS vector at startup. vector is not
-- a trusted extension, so on a fresh database only the superuser can create it.
CREATE EXTENSION IF NOT EXISTS vector SCHEMA public;

SELECT format('CREATE ROLE %I', 'aspirant_' || svc)
  FROM (SELECT DISTINCT svc FROM pg_temp.service_tables) s
 WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'aspirant_' || svc)
\gexec

-- Re-asserted every run, so a role altered by hand returns to this shape.
ALTER ROLE aspirant_transcriber WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'pw_transcriber';
ALTER ROLE aspirant_commander WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'pw_commander';
ALTER ROLE aspirant_advisor WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'pw_advisor';
ALTER ROLE aspirant_browser WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD :'pw_browser';

SELECT format('CREATE SCHEMA IF NOT EXISTS %1$I AUTHORIZATION %1$I', r),
       format('ALTER SCHEMA %1$I OWNER TO %1$I', r),
       format('ALTER ROLE %1$I SET search_path = %1$I, public', r),
       format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), r)
  FROM (SELECT DISTINCT 'aspirant_' || svc AS r FROM pg_temp.service_tables) s
\gexec

-- Moves, in an order that keeps every view and grant resolvable: commander
-- moves before transcriber, transcriber returns before commander. A move
-- carries the table's indexes, constraints, owned sequences and grants.
SELECT 'DROP VIEW IF EXISTS aspirant_commander.voice_messages'
\gexec
SELECT format('ALTER TABLE public.%I SET SCHEMA %I', l.tbl, 'aspirant_' || l.svc)
  FROM pg_temp.located l JOIN pg_temp.request r ON r.svc = l.svc AND r.op = 'move'
 WHERE l.place = 'public'
 ORDER BY l.svc = 'transcriber', l.svc, l.tbl
\gexec
SELECT format('ALTER TABLE %I.%I SET SCHEMA public', l.schema, l.tbl),
       format('ALTER TABLE public.%I OWNER TO %I', l.tbl, current_user)
  FROM pg_temp.located l JOIN pg_temp.request r ON r.svc = l.svc AND r.op = 'unmove'
 WHERE l.place = 'own'
 ORDER BY l.svc = 'commander', l.svc, l.tbl
\gexec

-- A table in a service's schema belongs to that service.
SELECT format('ALTER TABLE %I.%I OWNER TO %I', l.schema, l.tbl, l.schema)
  FROM pg_temp.located l
 WHERE l.place = 'own'
\gexec

-- Commander's one cross-service read. The grant travels with the table. When
-- voice_messages is in transcriber's schema, commander reaches it through a view
-- in its own schema, rather than by putting transcriber's schema on its path,
-- where transcriber could plant functions commander's sessions resolve.
SELECT format('GRANT SELECT ON %I.voice_messages TO aspirant_commander', l.schema)
  FROM pg_temp.located l
 WHERE l.tbl = 'voice_messages'
\gexec
SELECT 'GRANT USAGE ON SCHEMA aspirant_transcriber TO aspirant_commander',
       'CREATE VIEW aspirant_commander.voice_messages AS SELECT * FROM aspirant_transcriber.voice_messages',
       'ALTER VIEW aspirant_commander.voice_messages OWNER TO aspirant_commander'
  FROM pg_temp.located l
 WHERE l.tbl = 'voice_messages' AND l.place = 'own'
\gexec
SELECT 'REVOKE USAGE ON SCHEMA aspirant_transcriber FROM aspirant_commander'
  FROM pg_temp.located l
 WHERE l.tbl = 'voice_messages' AND l.place = 'public'
\gexec

-- The system_3 cell-signal reader (#5539) reads processed_valuations
-- unqualified. system_3's provision_aspirant_signal_ro.py owns the role, its
-- password and its SELECT grant, which travels with the table; this only
-- points the role's path at wherever the table is.
SELECT CASE l.place
         WHEN 'own' THEN 'GRANT USAGE ON SCHEMA aspirant_commander TO aspirant_signal_ro; '
                         'ALTER ROLE aspirant_signal_ro SET search_path = aspirant_commander'
         ELSE 'REVOKE USAGE ON SCHEMA aspirant_commander FROM aspirant_signal_ro; '
              'ALTER ROLE aspirant_signal_ro RESET search_path'
       END
  FROM pg_temp.located l
 WHERE l.tbl = 'processed_valuations'
   AND EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'aspirant_signal_ro')
\gexec

COMMIT;

\pset footer off
SELECT 'aspirant_' || l.svc AS role,
       (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = 'aspirant_' || l.svc) AS superuser,
       count(*) FILTER (WHERE l.place = 'own') AS tables_in_own_schema,
       count(*) FILTER (WHERE l.place = 'public') AS tables_in_public
  FROM pg_temp.located l
 GROUP BY l.svc
 ORDER BY l.svc;
