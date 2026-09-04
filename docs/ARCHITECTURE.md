# Aspirant Platform Architecture

## System Overview

The Aspirant platform is a collection of independent microservices orchestrated by Docker Compose. Each service lives in its own repository, has its own CI/CD pipeline, and can be developed and deployed independently.

## Service Topology

```
Internet
  │
  ▼
┌─────────────────────────────────┐
│  aspirant-client (Nginx)        │
│  Port 80                        │
│                                 │
│  Static files: Vue.js SPA       │
│  Proxy: /api/ → server:8080     │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  aspirant-server (Go/Gin)       │
│  Port 8080 (exposed as 8081)    │
│                                 │
│  - Authentication (JWT)         │
│  - User management (RBAC)       │
│  - File management              │
│  - Game logic + scores          │
│  - Proxy to microservices       │
│                                 │
│  Env vars for service discovery:│
│  TRANSCRIBER_URL                │
│  COMMANDER_URL                  │
│  TRANSLATOR_URL                 │
└──┬──────────┬──────────┬────────┘
   │          │          │
   ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐
│Transcr.│ │Command.│ │Transl. │
│:8082   │ │:8083   │ │:8084   │
│        │ │        │ │        │
│Whisper │ │Parser  │ │Argos   │
│+Audio  │ │+Poller │ │Transl. │
└───┬────┘ └───┬────┘ └────────┘
    │          │          (stateless)
    ▼          ▼
┌─────────────────────────────────┐
│  PostgreSQL 16                  │
│  Port 5432                      │
│                                 │
│  Shared instance, tables owned  │
│  by individual services:        │
│                                 │
│  Server:      users, roles,     │
│               messages,         │
│               game_scores,      │
│               ludde_feeding_    │
│               times             │
│                                 │
│  Transcriber: voice_messages    │
│                                 │
│  Commander:   tasks, notes      │
└─────────────────────────────────┘
```

## Communication Patterns

### Client → Server
- Protocol: HTTP/HTTPS
- Mechanism: Nginx reverse proxy (`/api/` → `server:8080`)
- Auth: JWT token in `Authorization: Bearer` header

### Server → Microservices
- Protocol: HTTP (internal Docker network)
- Mechanism: Go HTTP client proxy
- Discovery: Environment variables (`TRANSCRIBER_URL`, etc.)
- Pattern: Server receives request, forwards to service, returns response

### Commander → Transcriber
- Protocol: Shared database (PostgreSQL)
- Pattern: Commander polls `voice_messages` table for new completed transcriptions
- No direct HTTP communication between these services

### Services → PostgreSQL
- Protocol: PostgreSQL wire protocol
- Connection: `DB_HOST=postgres` (Docker DNS)
- Schema management: Each service auto-migrates its own tables on startup

## Data Flow Examples

### Voice Command Pipeline
```
1. Upload audio     → client → server(proxy) → transcriber
2. Transcribe       → transcriber → Whisper → voice_messages table
3. Poll + parse     → commander reads voice_messages → parses commands
4. Create entities  → commander writes to tasks/notes tables
5. View results     → client → server(proxy) → commander → tasks/notes
```

### Translation
```
1. Request          → client → server(proxy) → translator
2. Translate        → translator → Argos Translate (local, offline)
3. Response         → translator → server → client
```

### File Management
```
1. Upload           → client → server → Docker volume (/data/files)
2. Download         → client → server → reads from volume
3. Assets (images)  → client → server → local filesystem (/data/assets)
```

Asset serving uses an in-memory MD5 index built at startup. The client requests assets
by hash via `GET /fetch-object/:hash`, and the server does an O(1) lookup. See
`aspirant-server/server/storage/storage.go` for the `StorageBackend` interface.

## Volume Layout (Production)

Production uses bind mounts to the RAID1 array at `/data/aspirant/`:

```
/data/aspirant/
├── files/           → /data/files               (server: user file uploads)
├── assets/          → /data/assets              (server: static assets — images, audio, dictionary)
├── audio/           → /data/audio               (transcriber: voice recordings)
├── models/          → /data/models              (translator: Argos language models)
├── remarkable/      → /data/remarkable          (remarkable: tablet sync data)
├── advisor/         → /data/advisor             (advisor: RAG knowledge base)
└── ollama/          → /root/.ollama             (ollama: LLM model weights)
```

Development uses named Docker volumes (`pgdata-dev`, `filedata-dev`, `assetdata-dev`, etc.)
to keep dev data fully isolated from production.

## Network

All services share a single Docker Compose bridge network. Service names resolve via Docker DNS:
- `postgres` → PostgreSQL container
- `server` → Go API gateway
- `client` → Nginx frontend
- `transcriber` → Whisper service
- `commander` → Command parser
- `translator` → Translation service
- `monitor` → System monitoring sidecar
- `remarkable` → reMarkable tablet integration
- `advisor` → RAG knowledge base
- `ollama` → Local LLM runtime
- `browser` → aspirant-browser (agentic browser flows). Internal-only:
  no host `ports:` mapping in production. All ingress goes through
  `server:8080` with JWT + Admin/Trusted role checks, matching the
  reverse-proxy pattern used for the other Python services.

## Host Machine (aspirant-cell)

### Access
```bash
ssh cell                    # SSH alias configured in ~/.ssh/config
```

### Specs
- **OS:** Ubuntu 24.04 LTS (x86_64)
- **User:** `aspirant` (home: `/home/aspirant`)
- **Deploy dir:** `/home/aspirant/aspirant-deploy/`
- **Data dir:** `/data/aspirant/` (RAID1 array)
- **Docker:** Installed, managed by `aspirant` user

### Installed tools
- Docker, Docker Compose
- AWS CLI v2 (installed manually — `apt` package unavailable on 24.04)
- No Python pip, no package managers beyond apt

### Gotchas
- **Architecture is x86_64** — download `linux-x86_64` binaries, not `aarch64`
- **No pip** — install CLI tools via apt or manual binary downloads
- **AWS CLI** was installed for the S3-to-local migration; it is no longer needed for
  normal operations but remains available for any future AWS tasks
- **Locale warnings** are cosmetic — `LC_CTYPE` not fully configured, does not affect operation
