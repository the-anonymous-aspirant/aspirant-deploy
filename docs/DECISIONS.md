# Decisions

### Split from monorepo to polyrepo

**Context:** aspirant-online was a monorepo containing Go server, Vue client, and three Python microservices (transcriber, commander, translator). CI built all 5 images on every push.

**Problem:** The translator's heavy dependencies (PyTorch, ~3 GB) caused CI disk space failures, blocking deploys for all services. Build times grew linearly with service count.

**Decision:** Split each service into its own repository with independent CI/CD pipelines. Create a deploy repo for orchestration.

**Consequences:**
- Each service has independent build/test/deploy cycles
- Cross-cutting changes require multiple PRs
- Local dev requires cloning multiple repos

### Shared PostgreSQL instance

**Context:** Transcriber and commander both need database access and share data (commander reads voice_messages created by transcriber).

**Decision:** Keep a single PostgreSQL instance shared across services. Each service owns its tables and manages its own schema via auto-migration.

**Alternatives considered:**
- Separate databases per service (rejected: commander needs to read transcriber's tables)
- API-based communication between transcriber and commander (rejected: adds complexity for a simple polling pattern)

### Deploy repo for orchestration

**Context:** With services in separate repos, the docker-compose files need a home.

**Decision:** Create aspirant-deploy as a standalone repo containing compose files, environment config, and platform-wide architecture docs.

**Alternatives considered:**
- Compose files in each service repo (rejected: no single place to manage the full stack)
- Git submodules (rejected: adds complexity, painful merge workflows)

### COMPOSE_PROJECT_NAME for volume compatibility

**Context:** Docker Compose prefixes volume and network names with the project name (defaults to directory name). The old monorepo created volumes like `aspirant-online_pgdata`. The new deploy repo would create `aspirant-deploy_pgdata`, resulting in empty volumes and data loss on migration.

**Decision:** Set `COMPOSE_PROJECT_NAME=aspirant-online` in `.env` so all volume, network, and container name prefixes remain identical to the old deployment.

**Alternatives considered:**
- Explicit `name:` on each volume (rejected: harder to maintain, must update every volume definition)
- Rename deploy directory to `aspirant-online` (rejected: confusing, directory name should match repo name)
- External volumes (rejected: requires manual volume creation, more operational steps)

### Bind mounts on RAID1 for bulk storage

**Context:** The host has a 98 GB SSD (root `/`) and a 1.8 TB RAID1 array (`/data`). Docker volumes for file uploads, audio recordings, and translator models were stored on the SSD alongside the OS and database.

**Decision:** Move filedata, audiodata, and translatordata from Docker named volumes to bind mounts on `/data/aspirant/`. Keep PostgreSQL (`pgdata`) on the SSD for I/O performance.

**Layout:**
- `/data/aspirant/files` → server `/data/files`
- `/data/aspirant/audio` → transcriber `/data/audio`
- `/data/aspirant/models` → translator `/data/models`

**Alternatives considered:**
- Move everything including PostgreSQL to RAID1 (rejected: database benefits from SSD random I/O)
- Relocate Docker data directory to `/data/docker` (rejected: over-engineered, only bulk data needs the space)

**Consequences:**
- 1.8 TB available for uploads, recordings, and models (was 98 GB)
- RAID1 provides disk redundancy for user data
- PostgreSQL retains SSD performance
- Old named volumes (`aspirant-online_filedata`, `aspirant-online_audiodata`, `aspirant-online_translatordata`) removed

### Merge aspirant-meta into aspirant-deploy

**Context:** aspirant-meta was a standalone repo containing development conventions, philosophy, infrastructure inventory, and project templates. aspirant-deploy was the central orchestration repo.

**Decision:** Merge meta content into deploy, making deploy the single source of truth for both deployment configuration and development standards.

**Rationale:**
- Infrastructure inventory describes deployed state — belongs with compose files
- Deploy is already the central coordination point across all services
- Eliminates a standalone repo that only held documentation
- Conventions and templates are now co-located with the deployment they govern

**Moved files:**
- `CONVENTIONS.md` → deploy root
- `DEVELOPMENT_PHILOSOPHY.md` → deploy root
- `INFRASTRUCTURE.md` → deploy root
- `_template/` → deploy root
- Cross-cutting decisions → `docs/DECISIONS.md` (this file)

---

## Cross-Cutting Architectural Decisions

*Migrated from aspirant-meta DECISIONS.md*

### Spec-driven development as the default workflow

**Context:** Establishing a development workflow for projects involving AI agent collaboration.

**Decision:** Every new service starts with documentation (spec, architecture, plan) before any code is written.

**Rationale:** AI agents produce better code when given a clear spec to implement. Without a spec, agents make assumptions that may not match intent, leading to rework. The spec also serves as a contract for verification.

### Independent Dockerized microservices for new capabilities

**Context:** Choosing between extending the Go monolith or building standalone services for new features like voice transcription.

**Decision:** Separate containerized services.

**Rationale:** Each service can use the right runtime (Python for ML, Go for API). Isolation means a crash in transcription doesn't take down the web app. Each service is independently testable.

### UUID primary keys for Python services, auto-increment for Go

**Context:** Multiple services share the same PostgreSQL database. Need to avoid primary key collisions.

**Decision:** UUID for Python (SQLAlchemy), auto-increment int for Go (GORM).

**Rationale:** Each ORM's default is the simplest path. UUIDs in Python naturally avoid collisions with Go tables. No cross-service foreign keys exist.

### Whisper base model over tiny or small

**Context:** Choosing Whisper model size for audio transcription on a home server (8 GB total RAM, 2 GB container limit).

**Decision:** `base` (74M params, ~1 GB).

**Rationale:** Fits within 2 GB with headroom. Accuracy is sufficient for personal voice notes. `tiny` would be faster but produce more transcription errors.

### Human-readable log format over structured JSON

**Context:** Choosing log format for multi-service Docker Compose stack.

**Decision:** Human-readable: `{timestamp} [{LEVEL}] {service}.{module}: {message}`

**Rationale:** No log aggregation platform is deployed. Primary consumer is a human reading `docker compose logs -f`. JSON logs are unreadable without tooling.

### Co-located tests over separate test repository

**Context:** Where to store tests for each microservice.

**Decision:** Co-located `tests/` inside each service directory.

**Rationale:** Each service is independent. Tests should follow the same principle — you can clone one service and run its tests without any other service.
