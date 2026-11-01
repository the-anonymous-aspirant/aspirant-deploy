# Aspirant Deploy Operations

## Prerequisites

- Docker and Docker Compose installed
- Access to GHCR (`ghcr.io/the-anonymous-aspirant/`) for production images
- For development: all service repos cloned as sibling directories

## Setup

### First-time setup

```bash
git clone git@github.com:the-anonymous-aspirant/aspirant-deploy.git
cd aspirant-deploy
cp .env.example .env
# Edit .env with real credentials
```

### Development setup

Clone all service repos as siblings:

```bash
cd ~/git
git clone git@github.com:the-anonymous-aspirant/aspirant-deploy.git
git clone git@github.com:the-anonymous-aspirant/aspirant-server.git
git clone git@github.com:the-anonymous-aspirant/aspirant-client.git
git clone git@github.com:the-anonymous-aspirant/aspirant-transcriber.git
git clone git@github.com:the-anonymous-aspirant/aspirant-commander.git
git clone git@github.com:the-anonymous-aspirant/aspirant-translator.git
```

Set dev credentials in `.env`:
```
DB_HOST=postgres
DB_USER=test_user
DB_PASSWORD=test_password
DB_NAME=test_db
```

## Running

### Production

```bash
docker compose pull
docker compose up -d
```

### Auto-pull on `:latest` image push

`scripts/auto-pull.sh` polls every aspirant-* service whose compose `image:` is `ghcr.io/the-anonymous-aspirant/aspirant-*:latest`. Membership is read from the ref each container was *created* from (`docker inspect … {{.Config.Image}}`), not from the ref `docker compose ps` prints: the ps column resolves through the local tag store and becomes a bare `sha256:…` as soon as `:latest` moves off the running image — after a hand `docker pull`, or after this script's own failed blue/green (the pull re-points `:latest` at the candidate before `deploy-client.sh` health-checks it, and a rollback leaves it there). Keyed on the ps column, a service in that state silently left the sweep; on 2026-08-26 client-* did, and 20 merged aspirant-client PRs sat undeployed for two days with no decision line (system_3 #4489, fix #4507). Keyed on the create-time ref, it stays in, and the next ticks say `deferred_known_bad` until a good build lands. When the local image SHA drifts from the running container's image SHA, it recreates the container (or, for `client`, delegates to `scripts/deploy-client.sh` for the blue/green swap). Each decision is appended as one JSON line to `/var/log/aspirant-auto-pull/decisions.jsonl`; a pull the registry refuses is one of them (`pull_failed`, below) and is never recorded as `no_change`. Failed deploys (container not running after `ASPIRANT_AUTO_PULL_HEALTH_WAIT` seconds, default 30 s) record the new SHA in `/var/lib/aspirant-auto-pull/known-bad.txt` so subsequent ticks skip the bad image instead of looping on it forever.

Install on the cell:

```bash
sudo install -d -o aspirant -g aspirant /var/log/aspirant-auto-pull /var/lib/aspirant-auto-pull
( crontab -l 2>/dev/null; echo '*/5 * * * * /home/aspirant/aspirant-deploy/scripts/auto-pull.sh >> /var/log/aspirant-auto-pull/cron.log 2>&1' ) | crontab -
```

#### Deploy gates

Two gates run once per tick, before any `docker compose pull` or recreate. Both log to the cron log and append a `service: "-"` line to `decisions.jsonl`.

**1. Maintenance pause.** While `/home/aspirant/aspirant-deploy/.maintenance-pause` exists, every tick is a logged no-op and the run exits 0 — a sanctioned freeze is not a fault. Open and close a window with:

```bash
touch /home/aspirant/aspirant-deploy/.maintenance-pause   # freeze
rm    /home/aspirant/aspirant-deploy/.maintenance-pause   # resume
```

Presence alone is the signal; the file is never read, so an unreadable marker cannot crash the cron, and anything written into it is advisory metadata for whoever finds it (who paused, why, when). The marker is gitignored — a committed one would freeze every checkout permanently.

The filename and contract match the system_3 side (`shared/paths.py::MAINTENANCE_MARKER_NAME`), but each host carries its own marker: the dev box and the cell share no filesystem, so a freeze is two commands, not one. Pausing both is the operator's job.

**2. Checkout provenance.** `auto-pull.sh` drives `docker compose` against the `docker-compose.yml` *in this checkout*, so a checkout parked on a feature branch would recreate production services from an unreviewed compose file. The run refuses unless `HEAD` is `main` tracking `origin/main`, exiting 1 with the drift reason and the fix command. A detached HEAD, a missing upstream, and a directory that is not a git checkout at all are all refusals — the gate needs to *prove* provenance, not merely fail to disprove it.

**3. Checkout freshness.** Gate 2 proves the checkout is release-*tracking*; it does not prove it is release-*current*. A checkout six PRs behind on `main` satisfies it cleanly, which is exactly how the cell sat at PR #50 while `origin/main` was at #56 (system_3 #2520) — nothing on this host has ever pulled the checkout, since `auto-pull.sh` polls images and contains no git operation, and no other cron does either. Because the compose file being deployed comes from this checkout, image updates were still being recreated every five minutes from six-PR-old config, silently. Stale documentation was never the risk.

This gate **self-heals when it can, reports either way, and never refuses.** On drift it fast-forwards the checkout onto `origin/main` when git can prove that loses nothing — no tracked file modified or staged, and `HEAD` an ancestor of `origin/main` — and appends one `checkout_ff` decision carrying the old and new commit:

```json
{"ts":"...","service":"-","action":"checkout_ff","from_sha":"2681d23…","to_sha":"878ef77…","reason":"behind:11"}
```

The rest of that tick deploys from the released compose file; the next tick runs the released copy of the script (git replaces files by inode, so the copy bash is already executing is unaffected). When it cannot fast-forward it appends `checkout_stale` as before, now **with the reason**, and warns on stderr:

```json
{"ts":"...","service":"-","action":"checkout_stale","from_sha":"","to_sha":"","reason":"behind:3;refused:tracked_changes"}
{"ts":"...","service":"-","action":"checkout_stale","from_sha":"","to_sha":"","reason":"behind:3;refused:not_fast_forward"}
```

`refused:tracked_changes` means someone is mid-edit in the deploy tree (untracked files, including the stray `.bak`s, never count); `refused:not_fast_forward` means `main` carries a local commit and only a person can say whether it is a hotfix or a mistake. Both are the human-action cases, which is why they are the only ones left in the log. Under `--dry-run` the checkout is untouched and the tick logs `would_checkout_ff` with the preflight verdict (`behind:N;ok` or `behind:N;refused:…`). A maintenance pause (gate 1) freezes the checkout too, since it exits before this gate runs.

It is silent when the checkout is current, so the ledger does not fill with a line per tick. The fetch is read-only and best-effort: an unreachable origin logs `checkout_freshness_unknown` rather than blocking, because a detector that turns this host's flaky uplink into a deploy outage would be a worse defect than the one it reports.

History: system_3 #2534 shipped this gate report-only and left "should staleness escalate to a refusal?" open. What happened instead was neither — `checkout_stale` fired on essentially every tick from 2026-07-20 to 2026-08-29, forty days, reaching `behind:11`, and nobody pulled (system_3 #4537). A refusal would have wedged every image deploy over a compose-file lag; the fast-forward is the command the warning was asking a human to run, done by the process that already knows it is needed, only when git proves it is lossless.

Neither of the first two gates inspects the working tree for uncommitted or untracked files. The cell carries stray `.env.bak-*` and `docker-compose.yml.bak-*` files; sweeping those into a cleanliness check would wedge every deploy for a reason that has nothing to do with which compose file is being deployed.

Dry-run from the deploy directory to see what *would* happen without pulling or recreating:

```bash
./scripts/auto-pull.sh --dry-run
```

To force a single new SHA back into rotation after a fix lands, drop it from the known-bad cache:

```bash
sed -i '/sha256:abc.../d' /var/lib/aspirant-auto-pull/known-bad.txt
```

#### Failed pulls (`pull_failed`)

A pull that the registry denies or that cannot reach it is logged as its own decision:

```json
{"ts":"…","service":"commander","action":"pull_failed","from_sha":"sha256:…","to_sha":"","reason":"rc=1;consecutive=3;Error response from daemon: Head \"https://ghcr.io/v2/…\": denied: denied"}
```

`reason` carries the pull's exit code, how many ticks in a row have now failed for that service, and the last line of docker's stderr (the first lines are per-image progress, not the error).

After a failed pull the tick still deploys a locally cached image that differs from the running one — hand-loading the image and letting this gate recreate the container is the sanctioned recovery while the registry lane is down (that is how the 2026-09 outage was unblocked), so `pull_failed` and `deployed` can appear for the same service on one tick. It logs nothing further in any other case: `no_change` after a denied pull is exactly the thing this decision exists to stop being written.

The streak is also written to `/var/lib/aspirant-auto-pull/pull-failures/<service>` and removed on the next success, so a sweep outside this script — the system_3 deploy-freshness reader, a cell-health row — can ask "has this lane been down for N ticks?" with a file read instead of parsing the ledger:

```bash
grep -c . /var/lib/aspirant-auto-pull/pull-failures/* 2>/dev/null   # nothing listed == every lane pulling
```

History: until system_3 #6252 the pull ran as `docker compose pull "$svc" >/dev/null 2>&1 || true`. A failing pull left the local `:latest` tag where it was, so the local and running SHAs still matched and the tick logged `no_change`/`sha_match` — byte-identical to a healthy nothing-new tick. The stored ghcr.io credential died after 2026-09-17T11:06Z, every pull on the box failed `denied: denied` for the next 4.2 days across all nine polled services, and the ledger said `no_change` throughout. It surfaced only because one service's HEAD happened to move and the system_3 deploy-freshness `identity=stale` red fired (system_3 #6250). With no HEAD movement it would still be invisible. A one-off `pull_failed` line is signal, not noise: the reader groups by action, and the alternative was 1,100+ identical `no_change` lines hiding a dead lane.

### Development

```bash
docker compose -f docker-compose.dev.yml up -d
```

### Partial startup (only specific services)

```bash
# Just server + database
docker compose -f docker-compose.dev.yml up -d postgres server

# Add translator
docker compose -f docker-compose.dev.yml up -d translator
```

## Cloudflare DDNS credential

`scripts/update-dns.sh` keeps the `the-aspirant.com` and `home.the-aspirant.com` A records pointed at the cell's current public IP. It runs from the **`aspirant` user's** crontab (`*/5 * * * *` plus `@reboot`) and reads its credential from `~/.config/aspirant/ddns.env`. The script contains no token and exits 1 without making a request when the file is missing, unreadable, or has a blank value.

The env file is `aspirant`-owned, not root-owned: a root-owned `0600` file is unreadable by the job, and the failure is silent to anyone not tailing `~/ddns.log`.

### Install

```bash
install -D -m 600 scripts/ddns.env.template ~/.config/aspirant/ddns.env
${EDITOR:-vi} ~/.config/aspirant/ddns.env   # fill in all four values
```

### Rotate the token

Rotation and the script's cutover must land in the same window: the old token stops working the moment it is revoked, and DDNS is blind until the new one is in place. Budget a few minutes with the cell reachable.

```bash
# 1. Mint the replacement in the Cloudflare dashboard (dashboard-only — an
#    API token cannot mint or revoke tokens). Scope it as narrowly as the
#    dashboard allows for this job: Zone → DNS → Edit, on the-aspirant.com
#    only. Do NOT revoke the old token yet.

# 2. Put it in place on the cell.
ssh -p 41922 aspirant@home.the-aspirant.com
${EDITOR:-vi} ~/.config/aspirant/ddns.env   # replace CF_TOKEN

# 3. Prove the new token works before the old one dies. A successful run is
#    silent; failures land in ~/ddns.log.
~/aspirant-deploy/scripts/update-dns.sh; echo "exit=$?"
tail -5 ~/ddns.log

# 4. Confirm both records answer with the cell's current IP.
curl -s https://api.ipify.org; echo
dig +short the-aspirant.com; dig +short home.the-aspirant.com

# 5. Only now revoke the old token in the dashboard, then re-run step 3 to
#    confirm nothing was still depending on it.
```

If step 3 fails, the old token is still live — restore the previous `CF_TOKEN` value in the env file and DDNS resumes on the next tick. Nothing else needs undoing.

### Verify

```bash
# The script never carries a credential of its own.
grep -nE '^(CF_TOKEN|ZONE_ID|ROOT_RECORD_ID|HOME_RECORD_ID)=' scripts/update-dns.sh   # no output

# The env file is not world-readable.
ssh -p 41922 aspirant@home.the-aspirant.com 'ls -l ~/.config/aspirant/ddns.env'       # -rw-------
```

## Per-service database roles

`transcriber`, `commander`, `advisor` and `browser` each have a login role of their own, `aspirant_<svc>`, with a schema of the same name (system_3 #9317). `DB_USER` is a Postgres superuser. A service that connects as it can:
- run shell commands in the postgres container (`COPY … TO PROGRAM`);
- read every table, `users` included;
- create roles.

Each service role instead:
- owns that service's tables, kept in its own schema, which heads its `search_path`. Server's tables stay in `public`.
- may read one other table: commander reads `voice_messages` through a view in its own schema.

None of the roles can create anything in `public`. A role that could would be able to plant a function or operator that a superuser session (server, backups, your `psql`) resolves to. That's the CVE-2018-1058 class, and `tests/db_roles_unit.sh` reproduces it as a control. Keeping the tables in `public` with a changed owner isn't enough either, because `CREATE INDEX` needs CREATE on the table's schema even when the index already exists.

`scripts/db-roles.sh` does it all from `scripts/db-roles.sql`, as the superuser inside the postgres container. It passes the passwords by name, so no value appears on a command line or in its output. It has three modes:

| command | what it does |
|---|---|
| `./scripts/db-roles.sh` | **Provision.** Creates the roles, their schemas and `search_path`, CONNECT, and the `vector` extension (untrusted, so only the superuser can create it). Idempotent, safe at any time, and never moves a table. |
| `./scripts/db-roles.sh move <svc>…` | Also moves those services' tables from `public` into their schemas, owned by their roles. Indexes, constraints, sequences and grants move with them. |
| `./scripts/db-roles.sh unmove <svc>…` | **Rollback.** Moves them back to `public`, owned by the superuser. |

Every mode refuses to proceed in any of these cases:
- a service table carries a trigger or rule, which would run as whoever writes to it, the superuser included after a rollback;
- a table exists in both places;
- the order is wrong: move commander before transcriber, and unmove transcriber before commander, because commander reads `voice_messages`.

A superuser session searches only `public`. So a service must already be connecting as its own role when its tables move, and must be back on the superuser when they move back. The cutover is per service: stop it, `move` it, start it as its role (system_3 #9320 has the compose side and the runbook).

```bash
cd ~/aspirant-deploy
# once: a password for each role, in .env (edit by hand; never echo them)
#   ASPIRANT_TRANSCRIBER_DB_PASSWORD, ASPIRANT_COMMANDER_DB_PASSWORD,
#   ASPIRANT_ADVISOR_DB_PASSWORD, ASPIRANT_BROWSER_DB_PASSWORD   (openssl rand -hex 32 each)
./scripts/db-roles.sh
# prints each role with superuser = f, and how many of its tables are in its schema vs public
```

`aspirant_signal_ro`, the system_3 cell-signal reader, keeps its SELECT grant when `processed_valuations` moves, because grants travel with the table. `db-roles.sh` points the role's `search_path` at commander's schema. Its password and grant stay with system_3's `scripts/provision_aspirant_signal_ro.py`.

`tests/db_roles_unit.sh` boots a throwaway `pgvector/pgvector:pg16` and runs each service image's real startup database code. It runs it first as the superuser, then as the service's role after `move`, and then checks:
- every refusal above;
- the attack control;
- the rollback;
- idempotence.

## Cloudflare Access lockout: break-glass

The admin paths (`/admin`, `/browser-flows`) sit behind a Cloudflare Access application that sends a One-time PIN to the operator's one address (system_3 decision `corpus/decisions/2026-07-20-admin-auth-second-factor.md`, option D; the applications are created by system_3 #8798). Three things lock the operator out of it: a Cloudflare outage, a lost mailbox, or a bad Access policy. None of them touches SSH, which does not pass through Cloudflare at all: `home.the-aspirant.com` is an unproxied A record pointing straight at the cell (see INFRASTRUCTURE.md, DNS Records) and sshd listens on 41922 (`Port 41922` in `/etc/ssh/sshd_config`). The DDNS cron above keeps that record current. This section is written ahead of the lockout on purpose: the path is only as good as the SSH key you last tested with it.

### 1. Get a shell on the cell

```bash
ssh -p 41922 aspirant@home.the-aspirant.com
```

Key-based only (`PasswordAuthentication no`, `AllowUsers aspirant`), so the device needs a key enrolled under `mesh/`. If the hostname does not answer, the A record may be stale: read the cell's current address from the Cloudflare DNS page or from the router, and use `ssh -p 41922 aspirant@<ip>`. `mesh/README.md` has the connection troubleshooting.

### 2. Reach the admin tools through the tunnel

Since system_3 #8798, Access protects more than the paths: aspirant-server issues the Admin tier only through `POST /login/admin` (the browser's `/admin/sign-in`). While the gate is on (`/health` reads `"admin_second_factor": "enforced"`), that route needs a Cloudflare Access assertion or the break-glass token, and the ordinary `/login` gives an admin account Member. A tunnel to the cell's port 80 still reaches every page, but its sign-in can't pass the gate.

The way in is the client nginx's break-glass listener, port 8098. It's published as `127.0.0.1:8098` only, by `scripts/deploy-client.sh`'s override. It's the same server block as the public hostname, so everything is behind it: `/admin/`, `/api/` (aspirant-server), `/browser-flows`, `/admin/penpot/`, `/admin/histoire/`. On this listener, and only for a connection that arrives through that loopback publish, nginx adds `X-Aspirant-Break-Glass` with the token to `/admin/sign-in`. The server accepts that in place of the assertion. The password is still required. Any other source on 8098 is refused (a compose sibling reaching the port directly), and so is a client that sends the header itself, on any port.

```bash
ssh -p 41922 -L 8080:127.0.0.1:8098 aspirant@home.the-aspirant.com
# then, in a browser on the laptop:
#   http://localhost:8080/admin/login
```

Sign in there with the admin password. No second port needs forwarding. Each break-glass use is logged by aspirant-server with its route and time. The token value is never logged.

Traffic that arrives this way never meets Access. The DOCKER-USER firewall that limits the public `:80` to Cloudflare's ranges doesn't apply either: it filters forwarded traffic, and a connection from the cell itself isn't forwarded (checked 2026-10-25 on `:80`).

#### The break-glass token

The token lives in two places, and they must hold the same value:

- `BREAK_GLASS_TOKEN` in the deploy checkout's `.env`, which aspirant-server reads through `env_file`;
- the client nginx's secrets drop-in `/data/aspirant/nginx-secrets/break-glass.conf`. It's mounted read-only into both client slots at `/etc/nginx/secrets/`, and nginx loads it with `include /etc/nginx/secrets/*.conf`, after `auth.conf`, the `X-System3-Auth` drop-in from system_3 #3019. Its whole content is one line:

  ```nginx
  set $break_glass_token "<the BREAK_GLASS_TOKEN value>";
  ```

To provision it or rotate it (system_3 #8798-B1 does the first one):

```bash
cd ~/aspirant-deploy
TOKEN="$(openssl rand -hex 32)"
# the drop-in: root-owned, 0600, like auth.conf
printf 'set $break_glass_token "%s";\n' "$TOKEN" | sudo install -m 0600 -o root -g root /dev/stdin /data/aspirant/nginx-secrets/break-glass.conf
# .env: replace the BREAK_GLASS_TOKEN= line with the same value (edit by hand; never echo it to a terminal you share)
unset TOKEN
docker compose up -d server                        # re-reads .env
docker compose exec client-blue nginx -s reload    # whichever slot is active (./scripts/deploy-client.sh status)
```

With no drop-in, or an empty `BREAK_GLASS_TOKEN`, break-glass is off. The server never accepts an empty token. The SSH key is still the first factor of this path, so a device that loses its key loses this way in too.

### 3. Turn the Access application off, or loosen it

Cloudflare dashboard → Zero Trust → Access → Applications. The dashboard signs in with the Cloudflare account's own credentials and second factor, not through Access, so an Access lockout never locks the dashboard.

- **Lost mailbox:** edit the application's policy and change the Include rule to an address you can read. The next PIN goes there.
- **Bad policy** (no one receives a PIN, or the wrong people pass): fix the policy. **Deleting the application no longer brings back the password-only admin login.** Without Access there's no assertion, and the server's gate refuses `/admin/sign-in`. Step 2 is the way in. To go back to the password alone, empty the three `CF_ACCESS_*` names in `.env` and run `docker compose up -d server`. The mode then reads `off`, and the mode change signs every Admin out once.
- **Cloudflare outage:** the dashboard is usually unreachable too. Use step 2 and wait; the public site is down regardless, because the root record is proxied.

### Verify the path while you are not locked out

Run this from the device you would use in a lockout. Repeat it whenever a device key, the Access policy or the break-glass token changes.

```bash
# sshd answers on the direct hostname (a key problem shows as "Permission denied (publickey)"; a stale record or a blocked port as a timeout)
ssh -p 41922 -o BatchMode=yes -o ConnectTimeout=10 aspirant@home.the-aspirant.com 'hostname'   # aspirant-cell

# 8098 is published on loopback only
ssh -p 41922 aspirant@home.the-aspirant.com 'ss -Hltn "sport = :8098"'   # one line, 127.0.0.1:8098, and no [::] or 0.0.0.0

# the admin UI answers through the break-glass tunnel without Cloudflare
ssh -p 41922 -f -N -o ExitOnForwardFailure=yes -L 8080:127.0.0.1:8098 aspirant@home.the-aspirant.com
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/admin/login   # 200
curl -s http://localhost:8080/api/health | grep -o '"admin_second_factor":"[a-z]*"'   # enforced (off before go-live)

# the gate passes on the tunnel's token. A made-up user tests it without a real password:
# 401 means the gate passed and the password was refused; 403 means the gate refused.
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{"username":"break-glass-probe","password":"x"}' http://localhost:8080/admin/sign-in   # 401
pkill -f 'ssh -p 41922 -f -N -o ExitOnForwardFailure=yes -L 8080'          # close the tunnel

# the same probe through port 80 carries no token, so with the gate on it's refused
ssh -p 41922 -f -N -o ExitOnForwardFailure=yes -L 8080:127.0.0.1:80 aspirant@home.the-aspirant.com
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
  -d '{"username":"break-glass-probe","password":"x"}' http://localhost:8080/admin/sign-in   # 403 (401 while the mode is off)
pkill -f 'ssh -p 41922 -f -N -o ExitOnForwardFailure=yes -L 8080'

# the header sent through the public hostname grants nothing
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'X-Aspirant-Break-Glass: anything' \
  https://the-aspirant.com/admin/sign-in   # never 200: nginx's 403, or Access's redirect to its login once the application is live
```

A `403` on the first `/admin/sign-in` probe means the server didn't accept the token. Check that `.env` and `break-glass.conf` hold the same value, and that both the server and the active client slot were restarted or reloaded after the last change.

## Testing

### Integration test suite

A comprehensive integration test script validates cross-service connectivity in three phases: direct health checks, proxy routes through the Go server, and data flow smoke tests.

```bash
# Run all integration tests (services must already be running)
./tests/integration.sh

# Show usage and available environment overrides
./tests/integration.sh --help
```

The script uses configurable retries (default: 30 attempts, 2 s apart) so it can be run immediately after `docker compose up -d` while services are still starting. Override defaults with environment variables:

```bash
HEALTH_RETRIES=10 HEALTH_SLEEP=5 ./tests/integration.sh
```

### Quick health checks

```bash
curl localhost:8081/health    # server
curl localhost:8082/health    # transcriber
curl localhost:8083/health    # commander
curl localhost:8084/health    # translator
```

### Service logs

```bash
docker compose logs -f                    # all services
docker compose logs -f server             # specific service
docker compose logs --tail=50 transcriber # last 50 lines
```

## Debugging

### Container shell access

```bash
docker compose exec server sh          # Alpine (server)
docker compose exec transcriber bash   # Debian (Python services)
docker compose exec postgres psql -U $DB_USER -d $DB_NAME  # Database
```

### Database inspection

```bash
# Connect to PostgreSQL
docker compose exec postgres psql -U $DB_USER -d $DB_NAME

# List tables
\dt

# Check voice messages
SELECT id, status, language FROM voice_messages ORDER BY uploaded_at DESC LIMIT 10;

# Check tasks
SELECT id, title, priority, status FROM tasks ORDER BY created_at DESC LIMIT 10;
```

### Rebuilding a single service

```bash
docker compose -f docker-compose.dev.yml build transcriber
docker compose -f docker-compose.dev.yml up -d transcriber
```

## Gotchas

- **Dev PostgreSQL port is 5433** (not 5432) to avoid conflicts with any local PostgreSQL
- **Dev volumes are separate** (`pgdata-dev`, etc.) so dev data never mixes with production
- **DB_HOST must be `postgres`** inside Docker networking. The `.env` value is overridden by `environment:` in the dev compose
- **Client depends on server** in dev compose — if server isn't running, Nginx proxy will return 502
- **Translator is stateless** — no `.env` needed, no database. It downloads language models on demand to its volume
- **Commander polls transcriber via database** — not HTTP. Both need the same PostgreSQL instance
- **Assets are served by MD5 hash** — the client requests `/fetch-object/{md5}` and the server looks up the file. If you add a new asset file, the server's in-memory index picks it up on restart. No database or config change needed
- **Multi-repo deploys require ordering** — when changes span server + client + deploy repos, build and push the server/client images *before* updating compose on the cell, otherwise `docker compose pull` fetches the old images
