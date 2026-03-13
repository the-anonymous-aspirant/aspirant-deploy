# Aspirant Deploy

Central hub for the Aspirant platform — deployment configuration, development conventions, infrastructure inventory, and project templates. This repo is the single source of truth for how services are deployed, built, and organized.

## Architecture

```
                         ┌─────────────────────┐
                         │   aspirant-client    │
                         │   Vue.js + Nginx     │
                         │   Port 80            │
                         └──────────┬───────────┘
                                    │
                           Nginx proxies /api/
                                    │
                                    ▼
                         ┌─────────────────────┐
         ┌──────────────▶│   aspirant-server    │◀──────────────┐
         │       ┌──────▶│   Go / Gin           │◀──────┐       │
         │       │       │   Port 8081 → 8080   │       │       │
         │       │       └──────────┬───────────┘       │       │
         │       │                  │                    │       │
     HTTP proxy  │            HTTP proxy            HTTP proxy   │
         │       │                  │                    │       │
         ▼       ▼                  ▼                    ▼       ▼
┌──────────┐ ┌──────────┐ ┌──────────────┐ ┌──────────┐ ┌──────────┐
│transcriber│ │commander │ │  translator  │ │ monitor  │ │remarkable│
│FastAPI    │ │FastAPI   │ │ FastAPI      │ │ FastAPI  │ │ FastAPI  │
│+Whisper   │ │+Parser   │ │ +Argos      │ │ +Docker  │ │ +rmc     │
│8082→8000  │ │8083→8000 │ │ 8084→8000   │ │8085→8000 │ │8086→8000 │
└─────┬─────┘ └────┬─────┘ └─────────────┘ └──────────┘ └──────────┘
      │            │
      ▼            ▼
┌──────────────────────────────────────────┐   ┌──────────────────┐
│              PostgreSQL 16               │   │     Kiwix        │
│              Port 5432                   │   │  Wikipedia serve  │
│              Volume: pgdata              │   │  (no proxy)      │
│                                          │   └──────────────────┘
│  Tables:                                 │
│  ├─ users, roles (server)                │   ┌──────────────────┐
│  ├─ messages, game_scores (server)       │   │     AWS S3       │
│  ├─ ludde_feeding_times (server)         │   │  (asset storage) │
│  ├─ voice_messages (transcriber)         │   └──────────────────┘
│  └─ tasks, notes (commander)             │
└──────────────────────────────────────────┘
```

## Service Map

| Service | Repository | Port | Tech | Database | Volumes |
|---------|-----------|------|------|----------|---------|
| **client** | [aspirant-client](https://github.com/the-anonymous-aspirant/aspirant-client) | 80, 8999 | Vue.js 3, Nginx | - | - |
| **server** | [aspirant-server](https://github.com/the-anonymous-aspirant/aspirant-server) | 8081→8080 | Go, Gin, GORM | users, roles, messages, game_scores, ludde_feeding_times | filedata |
| **transcriber** | [aspirant-transcriber](https://github.com/the-anonymous-aspirant/aspirant-transcriber) | 8082→8000 | Python, FastAPI, Whisper | voice_messages | audiodata |
| **commander** | [aspirant-commander](https://github.com/the-anonymous-aspirant/aspirant-commander) | 8083→8000 | Python, FastAPI | tasks, notes | - |
| **translator** | [aspirant-translator](https://github.com/the-anonymous-aspirant/aspirant-translator) | 8084→8000 | Python, FastAPI, Argos Translate | - | translatordata |
| **monitor** | [aspirant-monitor](https://github.com/the-anonymous-aspirant/aspirant-monitor) | 8085→8000 | Python, FastAPI | - | docker.sock (ro), /data (ro) |
| **remarkable** | [aspirant-remarkable](https://github.com/the-anonymous-aspirant/aspirant-remarkable) | 8086→8000 | Python, FastAPI, rmscene, rmc, cairosvg | - | remarkabledata |
| **kiwix** | [kiwix-serve](https://github.com/kiwix/kiwix-serve) (3rd party) | internal 8080 | C++, libzim | - | kiwixdata (ro) |
| **postgres** | (standard image) | 5432 | PostgreSQL 16 | all tables | pgdata |

## How Services Connect

### Server → Microservices (HTTP Proxy)

The Go server acts as an API gateway. It proxies requests to microservices using environment variables:

| Environment Variable | Default | Target |
|---------------------|---------|--------|
| `TRANSCRIBER_URL` | `http://transcriber:8000` | Voice transcription |
| `COMMANDER_URL` | `http://commander:8000` | Command parsing |
| `TRANSLATOR_URL` | `http://translator:8000` | Text translation |
| `MONITOR_URL` | `http://monitor:8000` | System monitoring |
| `KIWIX_URL` | `http://kiwix:8080` | Wikipedia offline |
| `REMARKABLE_URL` | `http://remarkable:8000` | reMarkable notebooks |

Docker Compose networking resolves service names (e.g., `transcriber`) to container IPs automatically.

### Client → Server (Nginx Reverse Proxy)

The Vue.js client is served by Nginx. The `default.conf` in aspirant-client proxies `/api/` requests to the server:

```
location /api/ → http://server:8080/
```

### Database Ownership

Each service owns its tables and manages its own schema (auto-migrate on startup):

- **Server (GORM):** users, roles, messages, game_scores, ludde_feeding_times
- **Transcriber (SQLAlchemy):** voice_messages
- **Commander (SQLAlchemy):** tasks, notes
- **Translator, Monitor, Remarkable, Kiwix:** no database (stateless)

### Data Flow: Voice → Command

```
1. User uploads audio    → client → server → transcriber (saves to DB + volume)
2. Transcriber processes → Whisper model → updates voice_messages.transcription
3. Commander polls       → reads new transcriptions from voice_messages table
4. Commander parses      → extracts commands → creates tasks/notes in DB
```

## Quick Start

### Production (pre-built images from GHCR)

```bash
cp .env.example .env
# Edit .env with real credentials

docker compose pull
docker compose up -d
```

### Development (build from source)

Requires all service repos cloned as siblings:

```
~/git/
├── aspirant-deploy/        ← you are here
├── aspirant-server/
├── aspirant-client/
├── aspirant-transcriber/
├── aspirant-commander/
├── aspirant-translator/
├── aspirant-monitor/
└── aspirant-remarkable/     ← remarkable service
```

```bash
cp .env.example .env
# Edit .env (DB_USER=test_user, DB_PASSWORD=test_password, DB_NAME=test_db)

docker compose -f docker-compose.dev.yml build
docker compose -f docker-compose.dev.yml up -d
```

### Health Checks

```bash
# All services (direct access)
curl http://localhost:8081/health          # server
curl http://localhost:8082/health          # transcriber
curl http://localhost:8083/health          # commander
curl http://localhost:8084/health          # translator
curl http://localhost:8085/health          # monitor
curl http://localhost:8086/health          # remarkable

# Via server proxy (requires auth token)
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/transcriber/health
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/commander/health
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/translator/health
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/remarkable/health
```

### Integration Tests

```bash
# Run after docker compose up -d
./tests/integration.sh
```

Tests validate direct health endpoints, proxied routes through the Go server, data flow smoke tests, and nginx reverse proxy connectivity.

## Volumes

| Volume | Container Path | Purpose | Backup Priority |
|--------|---------------|---------|-----------------|
| `pgdata` | `/var/lib/postgresql/data` | Database storage | High |
| `filedata` | `/data/files` | User-uploaded files (50 GB/user + 50 GB shared) | High |
| `audiodata` | `/data/audio` | Voice message recordings | Medium |
| `remarkabledata` | `/data/remarkable` | Synced reMarkable notebooks + to-device staging | Medium |
| `translatordata` | `/data/models` | Argos Translate language models (re-downloadable) | Low |
| `kiwixdata` | `/data` | Wikipedia ZIM files (re-downloadable) | Low |

## Port Allocation

| Port | Service | Environment |
|------|---------|-------------|
| 80 | client (Nginx) | Both |
| 5432 | PostgreSQL | Production |
| 5433 | PostgreSQL | Development |
| 8081 | server | Both |
| 8082 | transcriber | Both |
| 8083 | commander | Both |
| 8084 | translator | Both |
| 8085 | monitor | Both |
| 8086 | remarkable | Both |
| 8999 | client (alt) | Both |

## Environment Variables

See `.env.example` for the full list. Key variables:

| Variable | Used By | Required |
|----------|---------|----------|
| `DB_HOST` | server, transcriber, commander | Yes |
| `DB_USER` | postgres, server, transcriber, commander | Yes |
| `DB_PASSWORD` | postgres, server, transcriber, commander | Yes |
| `DB_NAME` | postgres, server, transcriber, commander | Yes |
| `AWS_ACCESS_KEY_ID` | server | Yes (for S3 assets) |
| `AWS_SECRET_ACCESS_KEY` | server | Yes (for S3 assets) |
| `AWS_REGION` | server | Yes |
| `S3_BUCKET_NAME` | server | Yes |

## Deployment

```bash
ssh aspirant
cd ~/aspirant-deploy
docker compose pull
docker compose up -d --force-recreate
docker compose logs -f  # verify startup
```

## Gotchas

1. **Nginx caches Docker DNS at startup.** The client container's Nginx resolves `server` to a container IP once, at process start. If you restart a backend service (e.g., `docker compose restart server`), it gets a new IP, but Nginx still points at the old one — resulting in `502 Bad Gateway` on all `/api/` requests. **Always restart the client container when restarting backend services:**

   ```bash
   # Correct: restart both together
   docker compose restart server client

   # Or use --force-recreate which handles it
   docker compose up -d --force-recreate
   ```

2. **`docker compose up -d` does not recreate running containers.** If you pulled new images, running `docker compose up -d` will say "Running" for containers whose config hasn't changed — even if the image is newer. Use `--force-recreate` to ensure new images are picked up:

   ```bash
   docker compose pull
   docker compose up -d --force-recreate
   ```

3. **Image naming follows the polyrepo.** Each service has its own repository and produces `ghcr.io/the-anonymous-aspirant/aspirant-{service}:latest`. For example, `aspirant-server`, `aspirant-client`, `aspirant-transcriber`, `aspirant-commander`, `aspirant-translator`, `aspirant-remarkable`, `aspirant-monitor`.

4. **Monitor needs Docker socket access.** The monitor service mounts `/var/run/docker.sock` read-only to inspect container status and `/data` read-only for disk usage reporting.

5. **Kiwix serves through the Go proxy, not directly.** Kiwix doesn't expose a host port. It's accessed via the Go server's proxy at `/api/wikipedia/...`.

## Conventions & Standards

Development standards, infrastructure inventory, and project templates live in this repo:

| File | Purpose | When to read |
|------|---------|--------------|
| [CONVENTIONS.md](CONVENTIONS.md) | Naming, API contracts, logging, testing, Docker, Git, database | When implementing — the rulebook |
| [DEVELOPMENT_PHILOSOPHY.md](DEVELOPMENT_PHILOSOPHY.md) | Values, principles, spec-driven workflow | Before starting a new project |
| [INFRASTRUCTURE.md](INFRASTRUCTURE.md) | Deployed services, ports, tables, volumes, DNS | When adding a service |
| [_template/](_template/) | Skeleton files for new services | When creating a new microservice |

## Adding a New Service

1. **Scaffold** — Copy the template: `cp -r _template/ ../aspirant-{name}/`
2. **Allocate** — Check [INFRASTRUCTURE.md](INFRASTRUCTURE.md) for the next available port (currently 8088). Reserve your tables and volumes
3. **Spec first** — Fill in `docs/SPEC.md` and `docs/ARCHITECTURE.md` before writing code. Get them reviewed
4. **Implement** — Follow [CONVENTIONS.md](CONVENTIONS.md): health endpoint, logging format, test categories (import, contract, command/output)
5. **Compose** — Add the service to both `docker-compose.yml` and `docker-compose.dev.yml`
6. **Validate** — Run the convention auditor: `python -m app.main scan ../aspirant-{name}` from [aspirant-auditor](https://github.com/the-anonymous-aspirant/aspirant-auditor)
7. **Update docs** — Add service details to INFRASTRUCTURE.md, log decisions in `docs/DECISIONS.md`, update CHANGELOG.md
8. **Ship** — Create GitHub repo, set up CI, push, PR compose changes into this repo, deploy

See [`_template/README.md`](_template/README.md) for the full pre/post-implementation checklist.

## Related Repositories

- [aspirant-auditor](https://github.com/the-anonymous-aspirant/aspirant-auditor) — Automated convention checker
- [aspirant-server](https://github.com/the-anonymous-aspirant/aspirant-server) — Go API gateway
- [aspirant-client](https://github.com/the-anonymous-aspirant/aspirant-client) — Vue.js frontend
- [aspirant-remarkable](https://github.com/the-anonymous-aspirant/aspirant-remarkable) — reMarkable rendering and sync service
- [aspirant-transcriber](https://github.com/the-anonymous-aspirant/aspirant-transcriber) — Whisper transcription service
- [aspirant-commander](https://github.com/the-anonymous-aspirant/aspirant-commander) — Voice command parser
- [aspirant-translator](https://github.com/the-anonymous-aspirant/aspirant-translator) — Argos Translate service
- [aspirant-monitor](https://github.com/the-anonymous-aspirant/aspirant-monitor) — System metrics service
- [aspirant-finance](https://github.com/the-anonymous-aspirant/aspirant-finance) — Financial transaction management
