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

`scripts/auto-pull.sh` polls every aspirant-* service whose compose `image:` is `ghcr.io/the-anonymous-aspirant/aspirant-*:latest`. Membership is read from the ref each container was *created* from (`docker inspect … {{.Config.Image}}`), not from the ref `docker compose ps` prints: the ps column resolves through the local tag store and becomes a bare `sha256:…` as soon as `:latest` moves off the running image — after a hand `docker pull`, or after this script's own failed blue/green (the pull re-points `:latest` at the candidate before `deploy-client.sh` health-checks it, and a rollback leaves it there). Keyed on the ps column, a service in that state silently left the sweep; on 2026-08-26 client-* did, and 20 merged aspirant-client PRs sat undeployed for two days with no decision line (system_3 #4489, fix #4507). Keyed on the create-time ref, it stays in, and the next ticks say `deferred_known_bad` until a good build lands. When the local image SHA drifts from the running container's image SHA, it recreates the container (or, for `client`, delegates to `scripts/deploy-client.sh` for the blue/green swap). Each decision is appended as one JSON line to `/var/log/aspirant-auto-pull/decisions.jsonl`. Failed deploys (container not running after `ASPIRANT_AUTO_PULL_HEALTH_WAIT` seconds, default 30 s) record the new SHA in `/var/lib/aspirant-auto-pull/known-bad.txt` so subsequent ticks skip the bad image instead of looping on it forever.

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

This gate **reports and continues**; it does not refuse. On drift it warns on stderr and appends one `checkout_stale` decision with the behind-count:

```json
{"ts":"...","service":"-","action":"checkout_stale","from_sha":"","to_sha":"","reason":"behind:3"}
```

It is silent when the checkout is current, so the ledger does not fill with a line per tick. The fetch is read-only and best-effort: an unreachable origin logs `checkout_freshness_unknown` rather than blocking, because a detector that turns this host's flaky uplink into a deploy outage would be a worse defect than the one it reports. Whether staleness should *escalate* to a refusal, as gate 2 does, is an open operator decision (system_3 #2534).

Neither of the first two gates inspects the working tree for uncommitted or untracked files. The cell carries stray `.env.bak-*` and `docker-compose.yml.bak-*` files; sweeping those into a cleanliness check would wedge every deploy for a reason that has nothing to do with which compose file is being deployed.

Dry-run from the deploy directory to see what *would* happen without pulling or recreating:

```bash
./scripts/auto-pull.sh --dry-run
```

To force a single new SHA back into rotation after a fix lands, drop it from the known-bad cache:

```bash
sed -i '/sha256:abc.../d' /var/lib/aspirant-auto-pull/known-bad.txt
```

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
