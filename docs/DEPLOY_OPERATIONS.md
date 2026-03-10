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

### Health checks

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
