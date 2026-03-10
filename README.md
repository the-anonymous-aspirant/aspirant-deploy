# Aspirant Deploy

Orchestration and deployment configuration for the Aspirant platform. This repo contains Docker Compose files, environment configuration, and architecture documentation that ties all services together.

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
         │               │   Go / Gin           │               │
         │               │   Port 8081 → 8080   │               │
         │               └──────────┬───────────┘               │
         │                          │                           │
     HTTP proxy               HTTP proxy                   HTTP proxy
         │                          │                           │
         ▼                          ▼                           ▼
┌─────────────────┐    ┌────────────────────┐    ┌─────────────────────┐
│ aspirant-       │    │ aspirant-          │    │ aspirant-           │
│ transcriber     │    │ commander          │    │ translator          │
│ FastAPI+Whisper │    │ FastAPI+Parser     │    │ FastAPI+Argos       │
│ Port 8082→8000  │    │ Port 8083→8000     │    │ Port 8084→8000      │
│                 │    │                    │    │                     │
│ Volume:         │    │                    │    │ Volume:             │
│ audiodata       │    │                    │    │ translatordata      │
└────────┬────────┘    └────────┬───────────┘    └─────────────────────┘
         │                      │
         ▼                      ▼
┌──────────────────────────────────────────┐
│              PostgreSQL 16               │
│              Port 5432                   │
│              Volume: pgdata              │
│                                          │
│  Tables:                                 │
│  ├─ users, roles (server)                │
│  ├─ messages, game_scores (server)       │
│  ├─ ludde_feeding_times (server)         │
│  ├─ voice_messages (transcriber)         │
│  └─ tasks, notes (commander)             │
└──────────────────────────────────────────┘

          ┌──────────────────┐
          │     AWS S3       │
          │  (asset storage) │
          └──────────────────┘
              ▲
              │ server reads/writes
              │ assets via S3 SDK
```

## Service Map

| Service | Repository | Port | Tech | Database | Volumes |
|---------|-----------|------|------|----------|---------|
| **client** | [aspirant-client](https://github.com/the-anonymous-aspirant/aspirant-client) | 80 | Vue.js 3, Nginx | - | - |
| **server** | [aspirant-server](https://github.com/the-anonymous-aspirant/aspirant-server) | 8081→8080 | Go, Gin, GORM | users, roles, messages, game_scores, ludde_feeding_times | filedata |
| **transcriber** | [aspirant-transcriber](https://github.com/the-anonymous-aspirant/aspirant-transcriber) | 8082→8000 | Python, FastAPI, Whisper | voice_messages | audiodata |
| **commander** | [aspirant-commander](https://github.com/the-anonymous-aspirant/aspirant-commander) | 8083→8000 | Python, FastAPI | tasks, notes | - |
| **translator** | [aspirant-translator](https://github.com/the-anonymous-aspirant/aspirant-translator) | 8084→8000 | Python, FastAPI, Argos Translate | - | translatordata |
| **postgres** | (standard image) | 5432 | PostgreSQL 16 | all tables | pgdata |

## How Services Connect

### Server → Microservices (HTTP Proxy)

The Go server acts as an API gateway. It proxies requests to microservices using environment variables:

| Environment Variable | Default | Target |
|---------------------|---------|--------|
| `TRANSCRIBER_URL` | `http://transcriber:8000` | Voice transcription |
| `COMMANDER_URL` | `http://commander:8000` | Command parsing |
| `TRANSLATOR_URL` | `http://translator:8000` | Text translation |

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
- **Translator:** no database (stateless)

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
└── aspirant-translator/
```

```bash
cp .env.example .env
# Edit .env (DB_USER=test_user, DB_PASSWORD=test_password, DB_NAME=test_db)

docker compose -f docker-compose.dev.yml build
docker compose -f docker-compose.dev.yml up -d
```

### Health Checks

```bash
# All services
curl http://localhost:8081/health          # server
curl http://localhost:8082/health          # transcriber
curl http://localhost:8083/health          # commander
curl http://localhost:8084/health          # translator

# Via server proxy (requires auth token)
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/transcriber/health
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/commander/health
curl -H "Authorization: Bearer $TOKEN" http://localhost:8081/translator/health
```

## Volumes

| Volume | Container Path | Purpose | Backup Priority |
|--------|---------------|---------|-----------------|
| `pgdata` | `/var/lib/postgresql/data` | Database storage | High |
| `filedata` | `/data/files` | User-uploaded files (50 GB/user + 50 GB shared) | High |
| `audiodata` | `/data/audio` | Voice message recordings | Medium |
| `translatordata` | `/data/models` | Argos Translate language models (re-downloadable) | Low |

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
docker compose up -d
docker compose logs -f  # verify startup
```

## Related Repositories

- [aspirant-meta](https://github.com/the-anonymous-aspirant/aspirant-meta) — Development conventions, philosophy, infrastructure standards
- [aspirant-online](https://github.com/the-anonymous-aspirant/aspirant-online) — Original monorepo (archived)
