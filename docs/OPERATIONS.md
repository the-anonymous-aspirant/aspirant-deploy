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

`scripts/auto-pull.sh` polls every aspirant-* service whose image is `ghcr.io/the-anonymous-aspirant/aspirant-*:latest`. When the local image SHA drifts from the running container's image SHA, it recreates the container (or, for `client`, delegates to `scripts/deploy-client.sh` for the blue/green swap). Each decision is appended as one JSON line to `/var/log/aspirant-auto-pull/decisions.jsonl`. Failed deploys (container not running after `ASPIRANT_AUTO_PULL_HEALTH_WAIT` seconds, default 30 s) record the new SHA in `/var/lib/aspirant-auto-pull/known-bad.txt` so subsequent ticks skip the bad image instead of looping on it forever.

Install on the cell:

```bash
sudo install -d -o aspirant -g aspirant /var/log/aspirant-auto-pull /var/lib/aspirant-auto-pull
( crontab -l 2>/dev/null; echo '*/5 * * * * /home/aspirant/aspirant-deploy/scripts/auto-pull.sh >> /var/log/aspirant-auto-pull/cron.log 2>&1' ) | crontab -
```

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
