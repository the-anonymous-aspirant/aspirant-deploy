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
1. Upload           → client → server → Docker volume (filedata)
2. Download         → client → server → reads from volume
3. Assets (images)  → client → server → AWS S3
```

## Volume Layout

```
Docker Volumes:
├── pgdata           → /var/lib/postgresql/data  (PostgreSQL)
├── filedata         → /data/files               (server: user files)
├── audiodata        → /data/audio               (transcriber: recordings)
└── translatordata   → /data/models              (translator: language models)
```

## Network

All services share a single Docker Compose bridge network. Service names resolve via Docker DNS:
- `postgres` → PostgreSQL container
- `server` → Go API gateway
- `client` → Nginx frontend
- `transcriber` → Whisper service
- `commander` → Command parser
- `translator` → Translation service
