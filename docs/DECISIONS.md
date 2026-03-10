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
