# Infrastructure Inventory

Current state of everything deployed across projects following these standards. Each project section documents its services, tables, ports, and volumes. Update the relevant section whenever infrastructure changes.

When adding a new service, also follow the naming and contract standards in [CONVENTIONS.md](CONVENTIONS.md). For architectural rationale, see [DECISIONS.md](DECISIONS.md).

*Last updated: 2026-03-12*

---

## aspirant platform

Full-stack web platform (Go + Vue.js + Python microservices) running on a single home server. Each service lives in its own GitHub repository with its own CI/CD pipeline (polyrepo architecture).

---

## System Overview

```
                        ┌─────────────────────────────┐
                        │        Cloudflare DNS        │
                        │                              │
                        │  the-aspirant.com  (proxied) │
                        │  home.the-aspirant.com (DNS) │
                        └──────┬──────────────┬────────┘
                               │              │
                 ┌─────────────▼──┐     ┌─────▼─────────────┐
                 │  Cloudflare    │     │  Direct DNS        │
                 │  Proxy (CDN)   │     │  (no proxy)        │
                 │  HTTP/HTTPS    │     │  SSH :41922        │
                 └───────┬────────┘     └─────┬─────────────┘
                         │                    │
                         ▼                    ▼
  ┌──────────────────────────────────────────────────────────────────┐
  │                        Home Server                               │
  │                                                                  │
  │  ┌────────┐  ┌────────┐  ┌──────────┐  ┌─────────┐  ┌────────┐ │
  │  │ Client │  │ Server │  │Transcribe│  │Commander│  │Translat│ │
  │  │ Nginx  │  │ Go/Gin │  │ FastAPI  │  │ FastAPI │  │ FastAPI│ │
  │  │ :80    │  │ :8081  │  │ :8082    │  │ :8083   │  │ :8084  │ │
  │  └────────┘  └───┬────┘  └────┬─────┘  └────┬────┘  └────────┘ │
  │                  │            │              │                   │
  │  ┌────────┐  ┌───┴────┐  ┌───┴──────────────┴──┐  ┌──────────┐ │
  │  │Monitor │  │Remarkab│  │     PostgreSQL       │  │  Kiwix   │ │
  │  │ FastAPI│  │ FastAPI│  │       :5432          │  │ :8080    │ │
  │  │ :8085  │  │ :8086  │  └──────────┬───────────┘  │ (intern) │ │
  │  └────────┘  └────────┘            │              └──────────┘ │
  │                                     │                           │
  │  ┌────────┐                         │                           │
  │  │Finance │  ───depends on──────────┘                           │
  │  │ FastAPI│                                                     │
  │  │ :8087  │                                                     │
  │  └────────┘                                                     │
  │                                                                  │
  │  Volumes: pgdata filedata audiodata remarkabledata translatordata│
  │  Storage: AWS S3 (assets)                                        │
  └──────────────────────────────────────────────────────────────────┘
```

---

## Services

| Service | Repository | Tech | Container Image | Host Port | Container Port | Memory Limit |
|---------|-----------|------|----------------|-----------|---------------|-------------|
| **PostgreSQL** | — | postgres:16-alpine | — (official image) | 5432 | 5432 | — |
| **Server** | aspirant-server | Go 1.23 + Gin + GORM | `ghcr.io/.../aspirant-server` | 8081 | 8080 | — |
| **Client** | aspirant-client | Vue 3 + Vuetify + Nginx | `ghcr.io/.../aspirant-client` | 80, 8999 | 80 | — |
| **Transcriber** | aspirant-transcriber | Python 3.11 + FastAPI + Whisper | `ghcr.io/.../aspirant-transcriber` | 8082 | 8000 | 2 GB |
| **Commander** | aspirant-commander | Python 3.11 + FastAPI + SQLAlchemy + dateparser | `ghcr.io/.../aspirant-commander` | 8083 | 8000 | — |
| **Translator** | aspirant-translator | Python 3.11 + FastAPI + Argos Translate | `ghcr.io/.../aspirant-translator` | 8084 | 8000 | 2 GB |
| **Monitor** | aspirant-monitor | Python 3.11 + FastAPI + Docker SDK | `ghcr.io/.../aspirant-monitor` | 8085 | 8000 | — |
| **Remarkable** | aspirant-remarkable | Python 3.11 + FastAPI + rmscene + rmc + cairosvg | `ghcr.io/.../aspirant-remarkable` | 8086 | 8000 | 2 GB |
| **Finance** | aspirant-finance | Python FastAPI | `ghcr.io/.../aspirant-finance` | 8087 | 8000 | — |
| **Kiwix** | — | kiwix-serve (3rd party) | `ghcr.io/kiwix/kiwix-serve` | — (internal) | 8080 | — |

### Service Dependencies

```
Client ──(standalone, no backend dependency)

Server ──depends on──▶ PostgreSQL (health check)
       ──connects to──▶ AWS S3
       ──proxies to──▶ Transcriber, Commander, Translator, Monitor, Kiwix, Remarkable, Finance

Transcriber ──depends on──▶ PostgreSQL (health check)

Commander ──depends on──▶ PostgreSQL (health check)
          ──reads from──▶ voice_messages table (owned by Transcriber)

Translator ──(standalone, no database)

Monitor ──connects to──▶ Docker socket (read-only)
        ──reads──▶ /data volume (disk usage)

Remarkable ──(standalone, no database)
           ──connects to──▶ reMarkable Paper Pro (SSH/rsync over LAN)

Finance ──depends on──▶ PostgreSQL (health check)

Kiwix ──(standalone, serves ZIM files)
```

---

## Database

**Engine:** PostgreSQL 16 (Alpine)
**Database name:** `aspirant_online_db`
**Connection:** `DB_HOST=postgres` (Docker networking)

### Tables

#### Owned by Server (Go/GORM)

| Table | Primary Key | Description | Key Columns |
|-------|------------|-------------|-------------|
| `users` | `id` (int, auto) | User accounts | username, email, password, role_id (FK) |
| `roles` | `id` (int, auto) | Access roles | role_name (unique), role_description |
| `game_scores` | `id` (int, auto) | Universal game leaderboard | user_id (FK), game, mode, score, metadata (JSONB) |
| `messages` | `id` (int, auto) | Message board posts | content, sender_id, sent_at, deleted_at (soft delete) |
| `ludde_feeding_times` | `id` (int, auto) | Pet feeding tracker | timestamp, comment |
| `templates` | `id` (int, auto) | Template/demo model | unique_not_null_field |

#### Owned by Transcriber (Python/SQLAlchemy)

| Table | Primary Key | Description | Key Columns |
|-------|------------|-------------|-------------|
| `voice_messages` | `id` (UUID) | Audio transcriptions | filename, status, transcription, language, whisper_model, duration_seconds |

#### Owned by Commander (Python/SQLAlchemy)

| Table | Primary Key | Description | Key Columns |
|-------|------------|-------------|-------------|
| `commander_tasks` | `id` (UUID) | Parsed task commands | title, due_date, status, source_message_id |
| `commander_processed` | `id` (UUID) | Tracking of processed transcriptions | voice_message_id, processed_at |

#### Owned by Finance (Python/SQLAlchemy)

| Table | Primary Key | Description | Key Columns |
|-------|------------|-------------|-------------|
| `finance_transactions` | `id` (UUID) | Financial transactions | transaction_hash (UNIQUE), transaction_date, payee, normalized_payee, amount, currency, transaction_type, reference, source_bank, source_file, account_id, category, flow_direction, absolute_amount, created_at, updated_at |
| `finance_categories` | `id` (UUID) | Category mapping rules | payee_pattern, category |
| `finance_payee_normalizations` | `id` (UUID) | Payee normalization rules | payee_pattern, canonical_payee |
| `finance_accounts` | `account_id` (PK) | Bank account definitions | account_name, bank, account_type |

### Roles (seeded)

| Role | Description |
|------|-------------|
| Admin | Full access + user management |
| Trusted | Family/trusted content access |
| User | Authenticated standard access |
| Gamer | Game-specific access |
| Guest | Public/read-only access |
| Deleted | Soft-deleted users |

---

## Storage

### Docker Volumes

| Volume | Mount Path | Owner | Contents |
|--------|-----------|-------|----------|
| `pgdata` | `/var/lib/postgresql/data` | PostgreSQL | Database files |
| `filedata` | `/data/files` | Server | User uploads (My Files + Shared Files, 50 GB limits) |
| `audiodata` | `/data/audio` | Transcriber | Voice message audio files |
| `translatordata` | `/data/models` | Translator | Argos translation language models (re-downloadable) |
| `remarkabledata` | `/data/remarkable` | Remarkable | Synced reMarkable notebook files + to-device staging |
| `kiwixdata` | `/data` | Kiwix | Wikipedia ZIM files (re-downloadable) |

### AWS S3

| Resource | Purpose |
|----------|---------|
| S3 Bucket | Game assets, static content, puzzle assets |

---

## Networking

### DNS Records (Cloudflare)

| Record | Type | Proxied | Purpose |
|--------|------|---------|---------|
| `the-aspirant.com` | A | Yes | Web traffic (HTTP/HTTPS via Cloudflare CDN) |
| `home.the-aspirant.com` | A | No | Direct access (SSH on port 41922) |

DNS is updated every 5 minutes by a cron job (`~/update-dns.sh`) to handle dynamic IP.

### Port Map

| Port | Service | Access |
|------|---------|--------|
| 22 (→41922) | SSH | Direct via `home.the-aspirant.com` |
| 80 | Client (Nginx) | Via Cloudflare proxy |
| 5432 | PostgreSQL | Internal only (localhost) |
| 8081 | Server API | Via Cloudflare proxy |
| 8082 | Transcriber API | Local network only |
| 8083 | Commander API | Local network only |
| 8084 | Translator API | Local network only |
| 8085 | Monitor API | Local network only |
| 8086 | Remarkable API | Local network only |
| 8087 | Finance API | Local network only |
| 8999 | Client (alt) | Alternate frontend port |

### Internal Docker Network

Services communicate by container name. The Go server acts as API gateway, proxying requests to microservices:

- `postgres` — database hostname
- `server` — Go API gateway
- `client` — frontend (standalone)
- `transcriber` — transcription API (proxied by server via `TRANSCRIBER_URL`, default `http://transcriber:8000`)
- `commander` — voice command parser (proxied by server via `COMMANDER_URL`, default `http://commander:8000`)
- `translator` — text translation (proxied by server via `TRANSLATOR_URL`, default `http://translator:8000`)
- `monitor` — system metrics (proxied by server via `MONITOR_URL`, default `http://monitor:8000`)
- `kiwix` — offline Wikipedia (proxied by server via `KIWIX_URL`, default `http://kiwix:8080`)
- `remarkable` — reMarkable notebook rendering (proxied by server via `REMARKABLE_URL`, default `http://remarkable:8000`)
- `finance` — financial transaction management (proxied by server via `FINANCE_URL`, default `http://finance:8000`)

### Device Mesh

Personal devices connect to aspirant-cell via SSH for shell access, file sync, or tunneling. Each device has its own Ed25519 key with per-device restrictions. Configuration and public keys are tracked in the `mesh/` directory.

| Device | Key Name | Access Level | Connection |
|--------|----------|-------------|------------|
| Laptop | `laptop` | Full shell + tunnel | On-demand SSH, persistent reverse tunnel on :2200 |
| Phone (Android) | `phone` | Full shell | On-demand SSH via Termux |
| reMarkable Paper Pro | `remarkable` | rsync only | Daily systemd timer |

**Reverse tunnel ports (reserved: 2200-2299):** 2200 = laptop.

See [mesh/README.md](mesh/README.md) for setup instructions, adding devices, and extending with reverse tunnels.

---

## CI/CD

### Polyrepo Pipelines

Each service has its own GitHub repository with an independent CI pipeline (`.github/workflows/ci.yml`).

**Trigger:** Push to `main` or PR to `main`

```
Per-repo: Checkout → Test → Login to GHCR → Build & push Docker image
```

**Images built (one per repo):**

| Repository | Image |
|-----------|-------|
| aspirant-server | `ghcr.io/the-anonymous-aspirant/aspirant-server:latest` |
| aspirant-client | `ghcr.io/the-anonymous-aspirant/aspirant-client:latest` |
| aspirant-transcriber | `ghcr.io/the-anonymous-aspirant/aspirant-transcriber:latest` |
| aspirant-commander | `ghcr.io/the-anonymous-aspirant/aspirant-commander:latest` |
| aspirant-translator | `ghcr.io/the-anonymous-aspirant/aspirant-translator:latest` |
| aspirant-monitor | `ghcr.io/the-anonymous-aspirant/aspirant-monitor:latest` |
| aspirant-remarkable | `ghcr.io/the-anonymous-aspirant/aspirant-remarkable:latest` |
| aspirant-finance | `ghcr.io/the-anonymous-aspirant/aspirant-finance:latest` |

**Retention:** 3 most recent versions kept, older versions deleted.

### Deployment Process

```bash
ssh aspirant
cd ~/aspirant-deploy
docker compose pull
docker compose up -d --force-recreate
```

No automated deployment — manual pull after CI builds complete.

**Important:** Always use `--force-recreate` to pick up new images. Always restart the client container when restarting backend services (nginx caches Docker DNS at startup).

---

## Authentication

| Component | Method | Details |
|-----------|--------|---------|
| Server API | JWT (24h expiry) | Bearer token in Authorization header |
| Transcriber API | None (v1) | Local network only, no auth |
| Commander API | None (v1) | Local network only, no auth |
| Translator API | None (v1) | Local network only, no auth |
| Monitor API | None (v1) | Local network only, no auth |
| Remarkable API | None (v1) | Local network only, no auth |
| Finance API | None (v1) | Local network only, no auth |
| SSH | Key-based | Port 41922, `~/.ssh/the_aspirant_git` |
| GHCR | GitHub PAT | `read:packages` scope, stored on server |

---

## Secrets & Configuration

### Runtime (`.env` file on server)

| Variable | Services | Sensitivity |
|----------|----------|-------------|
| `DB_USER` | Server, Transcriber, Commander | Low |
| `DB_PASSWORD` | Server, Transcriber, Commander | High |
| `DB_NAME` | Server, Transcriber, Commander | Low |
| `DB_HOST` | Server, Transcriber, Commander | Low |
| `AWS_ACCESS_KEY_ID` | Server | High |
| `AWS_SECRET_ACCESS_KEY` | Server | High |
| `AWS_REGION` | Server | Low |
| `S3_BUCKET_NAME` | Server | Low |
| `WHISPER_MODEL` | Transcriber | Low |
| `AUDIO_STORAGE_PATH` | Transcriber | Low |
| `TRANSCRIBER_URL` | Server | Low |
| `COMMANDER_URL` | Server | Low |
| `TRANSLATOR_URL` | Server | Low |
| `MONITOR_URL` | Server | Low |
| `KIWIX_URL` | Server | Low |
| `REMARKABLE_URL` | Server | Low |
| `FINANCE_URL` | Server | Low |

### Build-time (GitHub Secrets)

Same DB and AWS variables are passed as build args for the Server image.

---

## Monitoring

The **monitor** service provides container status, disk usage, and system metrics via API. Additionally:

| Check | Command |
|-------|---------|
| Container status | `docker compose ps` |
| Container logs | `docker compose logs -f {service}` |
| Resource usage | `docker stats` |
| Disk usage | `df -h` |
| Server health | `curl http://localhost:8081/health` |
| Transcriber health | `curl http://localhost:8082/health` |
| Commander health | `curl http://localhost:8083/health` |
| Translator health | `curl http://localhost:8084/health` |
| Monitor health | `curl http://localhost:8085/health` |
| Remarkable health | `curl http://localhost:8086/health` |
| Finance health | `curl http://localhost:8087/health` |
| DB connectivity | `pg_isready -U $DB_USER -d $DB_NAME` |
| Integration tests | `./tests/integration.sh` (in aspirant-deploy) |
