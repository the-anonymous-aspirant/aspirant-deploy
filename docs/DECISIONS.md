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
