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

### Dedicated postgres:15 + redis:7 for Penpot over the shared pgvector/pg16

**Context:** Penpot (third-party design tool, system_3 #2195) needs PostgreSQL and Redis. The platform convention is that aspirant-authored services share the single pgvector/pg16 instance.

**Decision:** Penpot gets its own `penpot-postgres` (postgres:15, digest-pinned) and `penpot-redis` on an isolated `penpot` network.

**Rationale:** Penpot is a third-party stack like ollama/kiwix, which also own their storage. A dedicated pg15 gives byte-identical restore parity with the proven dev-box instance (the content migration is a straight dump/restore), keeps Penpot's schema churn and upgrade cadence independent of the shared DB, and lets the whole sub-stack be backed up or dropped as a unit.

### Subdomain (design.the-aspirant.com) over a URL subpath for Penpot

> **Superseded (2026-07-16)** by "Admin subpath over the design subdomain" below.

**Context:** Public access to Penpot needs an origin. The apex domain already serves the client SPA.

**Decision:** A dedicated subdomain, proxied by the client nginx as a named vhost.

**Rationale:** Penpot documents root-URI deployment only (`PENPOT_PUBLIC_URI`, help.penpot.app technical guide — examples are all root subdomains; no subpath support is documented). `PENPOT_PUBLIC_URI` must also exactly match the browser origin or login silently fails.

### Admin subpath (the-aspirant.com/admin/penpot/) over the design subdomain

**Context:** Operator direction (system_3 #2198, 2026-07-16): ride the apex's proven TLS/Cloudflare/auth boundary instead of duplicating it on a second origin — the subdomain added a DDNS-untracked CNAME, an independently-failing origin dependency, and a second auth surface. The prior decision's premise ("no subpath support") was documentation-derived, not tested.

**Decision:** Penpot mounts at `location /admin/penpot/` on the apex server block, behind the existing admin `auth_request` gate, with a `config.js` short-circuit injecting a path-bearing `penpotPublicURI` and a matching path-bearing `PENPOT_PUBLIC_URI` on the backend. `design.the-aspirant.com` stays as a plain 302 to the path (workspace `#` deep links survive the redirect).

> The residual 302 alias was **withdrawn (2026-07-18)** — see "Decommission the design subdomain entirely" below. The subpath decision itself stands.

**Rationale:** Empirically falsified the root-URI-only premise on the live 2.16.2 stack (playwright spike, #2198 comment 8700): the frontend uses relative asset refs + hash routing and computes `public-uri = ensure_path_slash(penpotPublicURI || fallback)`; authenticated login, dashboard, path-prefixed websocket, RPC file creation, and full workspace render all stayed inside the prefix with zero escapes. The one console error (`css/ui.css` 404) reproduces identically at root — a pre-existing image quirk. Residual risk: the exporter path (PNG/PDF render round-trip) was not exercised in the spike; verify at cell dogfood.

### Proxied CNAME over a new A record for the design subdomain

> **Superseded (2026-07-18)** by "Decommission the design subdomain entirely" below — the CNAME is being removed, not re-pointed.

**Context:** The cell has a dynamic IP; `~/update-dns.sh` (cron, every 5 min) updates two hardcoded Cloudflare record IDs (apex + home).

**Decision:** `design.the-aspirant.com` is a Cloudflare-proxied CNAME to `the-aspirant.com`.

**Rationale:** The CNAME follows the apex A record automatically, so the DDNS script needs no third hardcoded record ID and the subdomain can never go stale on an IP change.

### Decommission the design subdomain entirely

**Context:** Operator direction (system_3 #2198, 2026-07-18): *"Regarding penpot, I would like for that to just be similar in structure to what we have with histoire."* Histoire is reached at `https://the-aspirant.com/admin/histoire/` behind the admin auth gate, with no subdomain of its own. The subpath decision above had already moved Penpot's real entry point to `/admin/penpot/` but left `design.the-aspirant.com` alive as a 302 alias; matching histoire means the alias goes too.

**Decision:** `design.the-aspirant.com` is removed — both the Cloudflare DNS record and the edge redirect rule. `https://the-aspirant.com/admin/penpot/` is the sole public entry point.

**Rationale:** An alias that no longer has a structural job is a maintenance and security surface rather than a convenience: a DNS record outliving its purpose is the classic subdomain-takeover precondition, and keeping it means every future ingress or TLS change has a second origin to reason about. The redirect bought only bookmark compatibility for a surface that has been operator-only and short-lived. Deep links survive regardless — the `/admin/penpot/` path preserves the workspace `#` fragment.

**State:** The redirect and record are served at the **Cloudflare edge**, not from this repo — `grep -rn "design\.the-aspirant" .` matches documentation only; no nginx vhost or compose entry exists to remove. Teardown is tracked on system_3 #2198 and splits by credential scope: the **CNAME can be deleted via API** with the token in the cell's `~/update-dns.sh`, which carries zone DNS edit scope; the **edge redirect rule cannot** — that token has no Ruleset permission (`/zones/<id>/rulesets` returns an authentication error), so removing the rule is operator action in the Cloudflare dashboard. Deleting the record alone closes the dangling-DNS surface: the rule is then unreachable rather than dangerous. Until that lands, `design.the-aspirant.com` continues to 302 — this entry records the decision, not a completed teardown.

### GHCR mirrors for the Penpot images over direct Docker Hub pulls

**Context:** The cell's docker daemon cannot complete TLS handshakes to registry-1.docker.io over the lossy Wi-Fi uplink (curl passes; the daemon's pull connections time out repeatedly), while ghcr.io answers in under a second. All first-party images already come from GHCR.

**Decision:** Mirror the five upstream Penpot images to `ghcr.io/the-anonymous-aspirant/penpot-*` (copied from the dev box via `docker buildx imagetools create`, digest-pinned in compose). They are mirrors, not builds — no build lane exists for them; upgrading Penpot means re-mirroring a new upstream digest.

**Rationale:** Registry-to-registry manifest copy preserves provenance (the source digest is recorded in docker-compose.yml comments), the cell demonstrably pulls GHCR reliably, and one registry for every image simplifies the auto-pull story.

### GHCR image + pre-push hook for publishing Histoire (over tarball-sync or on-cell build)

**Context:** The design-system component workbench (Histoire, static `histoire build` output) must be reachable on the cell at `the-aspirant.com/admin/histoire/` and stay current without anyone remembering a rebuild step (system_3 #2218; operator's sustainability framing). This repo family uses no GitHub Actions by design — tests and image publishing run locally.

**Decision:** `Dockerfile.histoire` in aspirant-design-system builds the static output inside the image (`npm ci` + `histoire build`, `HISTOIRE_BASE=/admin/histoire/` baked) and serves it with nginx at that same path; a tracked pre-push hook (`git config core.hooksPath scripts/git-hooks`, aspirant-browser precedent) publishes `ghcr.io/the-anonymous-aspirant/aspirant-histoire` on every push to main; the cell's auto-pull cron deploys `:latest` unattended.

**Alternatives considered:**
- Static tarball / OCI artifact + synced directory (rejected: requires inventing a new sync mechanism; every other deployable already rides GHCR + auto-pull)
- On-cell git-pull + `histoire build` (rejected: puts a node toolchain and npm-install traffic on a RAM-constrained box behind a radio link that kills long flows — see the #2195-B1 transfer saga)

**Rationale:** The image is fully self-contained — the DS repo builds alone, with node pinned by the base image, so the aspirant-client sibling-checkout gap (#2195 pre-flight finding 2) is structurally impossible. Merge-to-main and image-publish are the same human action. Failure mode if the hook is bypassed (`--no-verify` or a GitHub-side merge, which runs no local hooks): a stale but still-serving Histoire — rerun `scripts/build-and-push-image.sh` to catch up. Subpath serving is spike-verified (vite `base` honored by histoire 0.17.17; app renders behind the prefix with zero escaping requests).

### Post-merge publish poller for dev-box-built images (over local-push-only enforcement)

**Context:** aspirant-client, aspirant-browser, and aspirant-design-system images are built and pushed from the dev box by design (no CI publish — operator direction 2026-07-16). The publish trigger is a local `pre-push` hook, so a GitHub-side merge (UI button or system_3 auto-merge) publishes no image; auto-merge is enabled on client and browser, making that path routine. Bit twice: client#141 auto-merged with no image; design-system#23's bootstrap publish was manual. Full evidence and analysis: `docs/IMAGE_PUBLISH_DECISION.md` (system_3 #2281).

**Decision:** Add a dev-box post-merge publish poller (cron, `aspirant_auto_redeploy.py` operational shape): poll each repo's `origin/main` HEAD, and when GHCR holds no `sha-<short>` image for it, build from a freshly staged checkout (two-repo staged context for the client's `file:../aspirant-design-system` dependency) and push `:latest` + `:sha-<short>`. Extend the freshness sweep with a SHA-granular GHCR-vs-main publish-lag metric (plus an aspirant-histoire row) as the backstop that detects a wedged poller. Pre-push hooks remain as the fast path; the SHA-existence check makes the poller a no-op behind them.

**Alternatives considered:**
- Local-push-only merges as policy + freshness alert only (rejected: unenforceable without CI status checks, requires disabling auto-merge on the two most active image-bearing repos, and recovery still needs a human — fails the unattended-6-months criterion)
- Fixing the repos' GitHub `build-image.yml` workflows (out of scope: images are built locally by design per the 2026-07-16 operator direction; the client workflow also cannot see the design-system `file:` sibling)

**Rationale:** Decouples "image exists for main HEAD" from *which door the merge went through*; idempotent against the existing hooks; keeps auto-merge throughput; the backstop metric catches the poller's own failure mode.

**Status:** Proposed 2026-07-17 — ratified by merging this PR (system_3 #2281; implementation tasks listed in `docs/IMAGE_PUBLISH_DECISION.md` §Remediation).

### Application-level fail-fast over `depends_on: service_healthy` for reboot-order safety

**Context:** The server has declared `depends_on: postgres: condition: service_healthy` since the initial commit, yet the #2660 DB-init race still fired on a host reboot — the server came up before postgres was ready and crashed on DB init. `depends_on` ordering, including `condition: service_healthy`, is honored only by `docker compose up`. On a **host reboot** the Docker daemon restarts `restart: unless-stopped` containers in parallel and does not replay compose's dependency ordering, so any service can start ahead of a dependency it declared.

**Decision:** Do not rely on `depends_on` for reboot-time startup ordering. Each service guards its own dependencies at the application layer — fail fast (crash) when a required dependency is unavailable, so Docker's `restart: unless-stopped` policy retries until the dependency is up. aspirant-server does this by `log.Fatal`-ing on DB-init failure (aspirant-server PR #58, merged `c84d0b5`).

**Consequences:**
- `depends_on: condition: service_healthy` stays in compose — it still gives correct startup ordering for `docker compose up` (deploys, manual restarts) and documents the dependency graph.
- A new service that needs a dependency at startup must fail-fast on its absence rather than assume compose ordering protects it on reboot.
- The `depends_on` blocks in `docker-compose.yml` carry an inline comment pointing here so the caveat is visible at the point of use.
