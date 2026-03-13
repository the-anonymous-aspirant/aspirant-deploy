# Conventions

Standards and naming patterns for all projects following the [Development Philosophy](DEVELOPMENT_PHILOSOPHY.md). Follow these to keep things consistent and predictable.

When adding a new service, also update the [Infrastructure Inventory](INFRASTRUCTURE.md) with its ports, tables, and volumes.

---

## Git

### Branch Naming

```
{type}/{short-description}
```

| Prefix | When to use | Example |
|--------|-------------|---------|
| `feature/` | New functionality | `feature/voice-transcription` |
| `fix/` | Bug fixes | `fix/login-token-expiry` |
| `refactor/` | Restructuring without behavior change | `refactor/role-fk` |
| `security/` | Security improvements | `security/route-guards` |
| `docs/` | Documentation only | `docs/networking-and-dns` |

Rules:
- Lowercase, hyphen-separated
- Short but descriptive (2-4 words after the prefix)
- Never commit directly to `main`

### Commit Messages

```
{Verb} {what changed}
```

**Examples:**
- `Add voice transcription service`
- `Fix language detection confidence calculation`
- `Refactor role system from string to foreign key`
- `Polish 30 Year Gift card styling`
- `Migrate Word Weaver to universal scoring`

Rules:
- Imperative mood ("Add", not "Added" or "Adds")
- No period at the end
- First line under 72 characters
- Body (optional) explains *why*, separated by a blank line

### Pull Requests

- One feature/fix per PR
- PR title matches the commit message style
- Merge to `main` via GitHub PR (never direct push)
- Include a short summary section in the PR body explaining *what* and *why*
- Include a test plan section listing how to verify the change

**Authorship:**
- The human is the author of the PR. AI agents are tools, not contributors
- Do **not** add `Co-Authored-By` trailers for AI agents in commit messages
- Do **not** list AI agents as reviewers or assignees
- The person who owns the work owns the commit

---

## Docker

### Dockerfile Naming

```
Dockerfile-{ServiceName}
```

Located inside the service directory:

| Service | Dockerfile | Location |
|---------|-----------|----------|
| Go backend | `Dockerfile-Server` | `server/Dockerfile-Server` |
| Vue frontend | `Dockerfile-Client` | `client/Dockerfile-Client` |
| Python transcriber | `Dockerfile-Transcriber` | `transcriber/Dockerfile-Transcriber` |

### Container Image Naming

```
ghcr.io/{github-owner}/{project}-{service}:{tag}
```

Example: `ghcr.io/the-anonymous-aspirant/aspirant-online-server:latest`

Tags:
- `latest` — current main branch build
- `YYYY-MM-DD-HHmm` — timestamped build
- `YYYY-MM-DD-HHmm-{sha}` — timestamped + commit hash
- `pr-{number}` — pull request builds

### Port Allocation

Ports are assigned sequentially. Reserve the next available port when adding a service.

| Port (Host) | Port (Container) | Service | Protocol |
|-------------|-----------------|---------|----------|
| 80 | 80 | Client (Nginx) | HTTP |
| 5432 | 5432 | PostgreSQL | TCP |
| 8081 | 8080 | Server (Go/Gin) | HTTP |
| 8082 | 8000 | Transcriber (FastAPI) | HTTP |
| 8083 | — | *Next service* | — |
| 8999 | 80 | Client (alt) | HTTP |
| 41922 | 22 | SSH | TCP |

### Volume Naming

Named volumes use short, descriptive names:

| Volume | Mount Path | Purpose |
|--------|-----------|---------|
| `pgdata` | `/var/lib/postgresql/data` | PostgreSQL data |
| `filedata` | `/data/files` | User-uploaded files |
| `audiodata` | `/data/audio` | Voice message audio |

Pattern for new volumes: `{contenttype}data` (e.g., `imagedata`, `cachedata`)

### Resource Limits

- ML/heavy services: `mem_limit: 2g`
- Standard services: no explicit limit (rely on host resources)
- Always set limits on services that could consume unbounded memory

### Dev Compose (`docker-compose.dev.yml`)

The dev compose file must be self-contained — it should work on a clean machine with only Docker installed, without VPN, cloud access, or external databases.

**Rules:**

- **Include a local PostgreSQL service** — Dev compose includes its own `postgres:16-alpine` container so services don't depend on a remote database
- **Override `DB_HOST` via `environment:`** — The `environment:` block in compose takes precedence over `env_file:`. Set `DB_HOST: postgres` to route services to the local container instead of whatever remote host is in `.env`
- **Use a separate volume name** — Dev postgres uses `pgdata-dev` (not `pgdata`) to avoid collisions if production compose runs on the same machine
- **Avoid host port conflicts** — Map the dev postgres to a non-standard host port (e.g., `5433:5432`) since the developer may have a local PostgreSQL on 5432
- **Add `depends_on` with health checks** — Services that need the database wait for `postgres: condition: service_healthy` before starting
- **Client depends on server** — The Nginx client container resolves the `server` upstream at startup, so it must start after the server is running

**Pattern:**

```yaml
# docker-compose.dev.yml
services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: ${DB_USER}
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_DB: ${DB_NAME}
    volumes:
      - pgdata-dev:/var/lib/postgresql/data
    ports:
      - "5433:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER} -d ${DB_NAME}"]
      interval: 5s
      timeout: 5s
      retries: 5

  server:
    build: ...
    environment:
      DB_HOST: postgres        # Override .env to use local DB
    env_file:
      - .env
    depends_on:
      postgres:
        condition: service_healthy

  transcriber:
    build: ...
    environment:
      DB_HOST: postgres        # Override .env to use local DB
    env_file:
      - .env
    depends_on:
      postgres:
        condition: service_healthy

  client:
    build: ...
    depends_on:
      - server                 # Nginx needs 'server' hostname resolvable at startup

volumes:
  pgdata-dev:
```

**Why not just use the remote DB for dev?**

- The remote DB may not be reachable (VPN, DNS, firewall)
- Accidental writes to production data are impossible
- Tests and experiments can freely create/drop data
- The dev environment works offline

---

## Code

### Directory Layout (per service)

Each service lives in its own top-level directory:

```
{project}/
├── {service-a}/     # One directory per service
├── {service-b}/     # Each service is independent
├── {service-c}/     # Future services follow the same pattern
├── docs/            # Project-wide documentation
├── docker-compose.yml
└── docker-compose.dev.yml
```

### Python Services

- **Framework:** FastAPI
- **ORM:** SQLAlchemy with Pydantic schemas
- **Base image:** `python:3.11-slim` (not Alpine — ML libs don't compile on musl)
- **Dependency management:** `requirements.txt` with pinned versions
- **App structure:**
  ```
  {service}/
  ├── app/
  │   ├── __init__.py
  │   ├── main.py          # FastAPI app with lifespan
  │   ├── config.py         # Environment variables
  │   ├── database.py       # Engine, session, Base
  │   ├── models.py         # ORM models
  │   ├── schemas.py        # Pydantic models
  │   ├── routes.py         # API endpoints
  │   └── {domain}.py       # Domain-specific logic
  ├── tests/
  │   ├── __init__.py
  │   ├── conftest.py       # Test DB, test client fixtures
  │   ├── test_health.py    # Health contract tests
  │   └── test_{resource}.py  # Resource contract + CRUD tests
  ├── Dockerfile-{Name}
  └── requirements.txt
  ```

### Go Services

- **Framework:** Gin
- **ORM:** GORM
- **Base image:** `golang:1.23` build → `alpine` runtime (multi-stage)
- **App structure:**
  ```
  server/
  ├── data_models/     # GORM model definitions
  ├── data_functions/  # Business logic
  ├── handlers/        # HTTP handlers
  ├── middleware/       # Gin middleware
  ├── database.go      # Connection and migration
  ├── routes.go        # Route definitions
  └── Dockerfile-Server
  ```

### Vue.js Frontend

- **Framework:** Vue 3 + Vuetify + Vite
- **Base image:** `node:21-alpine` build → `nginx:alpine` runtime (multi-stage)
- **Structure:** Standard Vue SPA with `src/views/`, `src/components/`, `src/router/`

---

## Database

### Table Naming

- Lowercase, snake_case, plural: `voice_messages`, `game_scores`, `users`
- Junction tables: `{table_a}_{table_b}` alphabetically

### Column Naming

- Lowercase snake_case: `file_size_bytes`, `created_at`
- Foreign keys: `{referenced_table_singular}_id` (e.g., `user_id`, `role_id`)
- Timestamps: `created_at`, `updated_at`, `completed_at`, `deleted_at`
- Booleans: `is_` prefix (e.g., `is_active`)

### Primary Keys

- Go models: auto-increment integer `id` (via GORM)
- Python models: UUID `id` (avoids conflicts with Go tables)

### Migration Strategy

- **Go:** GORM `AutoMigrate` on startup
- **Python:** SQLAlchemy `Base.metadata.create_all()` on startup
- No separate migration tool — the application owns its schema

---

## API Contract

All REST services must follow these patterns for consistency. A client or agent interacting with any service should be able to predict the URL shape, error format, and pagination behavior without reading the docs.

### URL Patterns

```
/{resource}          # Collection (plural, lowercase, hyphen-separated)
/{resource}/{id}     # Single item
/{resource}/{id}/{sub-resource}  # Nested (only if tightly owned)
```

Rules:
- **Plural nouns** for collections: `/voice-messages`, `/game-scores`, `/users`
- **Kebab-case** for multi-word resources: `/voice-messages` not `/voiceMessages` or `/voice_messages`
- **No trailing slashes**
- **No verbs in URLs** — use HTTP methods: `POST /voice-messages` not `POST /create-voice-message`
- **Exception:** Action endpoints use `POST /{resource}/{id}/{verb}` (e.g., `POST /voice-messages/{id}/retry`)

### HTTP Methods

| Method | Purpose | Success Code | Returns |
|--------|---------|-------------|---------|
| `GET /{resource}` | List (paginated) | 200 | Collection response |
| `GET /{resource}/{id}` | Get single | 200 | Item |
| `POST /{resource}` | Create | 201 (sync) or 202 (async) | Created item or job reference |
| `PUT /{resource}/{id}` | Full replace | 200 | Updated item |
| `PATCH /{resource}/{id}` | Partial update | 200 | Updated item |
| `DELETE /{resource}/{id}` | Delete | 204 | Empty |

### Health Endpoint

Every service exposes `GET /health`. The response shape is standardized:

```json
{
  "status": "ok",
  "service": "transcriber",
  "version": "1.0.0",
  "checks": {
    "database": "connected",
    "storage": "available"
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `status` | string | Yes | `"ok"` if all checks pass, `"degraded"` if any fail |
| `service` | string | Yes | Service name (matches docker-compose service name) |
| `version` | string | Yes | Service version |
| `checks` | object | Yes | Key-value pairs of dependency → status |

Status codes:
- `200` when `status` is `"ok"`
- `200` when `status` is `"degraded"` (the service is reachable — downstream issues are reported in `checks`)

### Error Responses

All services return errors in the same shape:

```json
{
  "error": {
    "code": "validation_error",
    "message": "File too large. Maximum size is 25 MB.",
    "details": {}
  }
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `error.code` | string | Yes | Machine-readable error code (snake_case) |
| `error.message` | string | Yes | Human-readable explanation |
| `error.details` | object | No | Additional structured context |

Standard error codes:

| Code | HTTP Status | When |
|------|------------|------|
| `not_found` | 404 | Resource doesn't exist |
| `validation_error` | 400 | Bad input (wrong type, missing field, too large) |
| `conflict` | 409 | Duplicate or state conflict |
| `internal_error` | 500 | Unexpected server failure |
| `service_unavailable` | 503 | Dependency down |

### Pagination

List endpoints use offset-based pagination:

```
GET /voice-messages?page=1&page_size=20
```

Response wraps items in a standard envelope:

```json
{
  "items": [...],
  "total": 145,
  "page": 1,
  "page_size": 20
}
```

| Parameter | Default | Max | Description |
|-----------|---------|-----|-------------|
| `page` | 1 | — | 1-indexed page number |
| `page_size` | 20 | 100 | Items per page |

---

## Logging

Consistent log output across all services makes it possible to read interleaved `docker compose logs` without confusion.

### Format

All services use this format:

```
{ISO-8601 timestamp} [{LEVEL}] {service}.{module}: {message}
```

Example:
```
2026-03-09T14:23:01Z [INFO] transcriber.routes: Upload accepted, id=550e8400, file=recording.wav, size=2.1MB
2026-03-09T14:23:01Z [INFO] transcriber.tasks: Transcription started, id=550e8400
2026-03-09T14:23:18Z [INFO] transcriber.tasks: Transcription complete, id=550e8400, duration=17.2s, language=en
2026-03-09T14:23:45Z [WARNING] transcriber.tasks: Retry queued, id=550e8400, attempt=2, reason=timeout
2026-03-09T14:24:01Z [ERROR] transcriber.tasks: Transcription failed, id=550e8400, error=ModelOOM
```

### Python (FastAPI) logging config

```python
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
```

### Go (Gin) logging config

Use Gin's default logger with structured fields. Prefix log lines with service name.

### Log Levels

| Level | When to use | Examples |
|-------|-------------|---------|
| `DEBUG` | Development only. Never in production | Variable values, raw payloads, step-by-step traces |
| `INFO` | Normal operations worth recording | Request accepted, task completed, startup/shutdown, config loaded |
| `WARNING` | Something unexpected that was handled | Retry triggered, fallback used, deprecated endpoint called |
| `ERROR` | Something failed and needs attention | Unhandled exception, DB connection lost, task failed permanently |

### What to include in log messages

- **Resource identifiers** — Always include the ID of the thing being processed (`id=550e8400`)
- **Measurable context** — Durations, sizes, counts (`duration=17.2s`, `size=2.1MB`)
- **Status transitions** — What happened (`started`, `completed`, `failed`, `retried`)
- **Never log:** Passwords, tokens, full request bodies, PII

### What NOT to log

- Do not log at INFO level for every incoming HTTP request — the framework's access log handles that
- Do not log success for trivial operations (health checks, static files)
- Do not duplicate what `docker compose logs` already timestamps — use relative time references in messages, not absolute

---

## Testing

Tests verify that the service works as specified. They live inside the service directory, co-located with the code they test.

See also: [Development Philosophy → Testing Philosophy](DEVELOPMENT_PHILOSOPHY.md#testing-philosophy)

### Test Location

```
{service}/
├── app/
│   ├── main.py
│   └── ...
├── tests/                    # Tests live here
│   ├── __init__.py
│   ├── conftest.py           # Shared fixtures (test DB, test client)
│   ├── test_health.py        # Health endpoint contract
│   ├── test_{resource}.py    # Resource CRUD contracts
│   └── test_{domain}.py      # Domain logic tests
├── Dockerfile-{Name}
└── requirements.txt
```

Tests are inside the service directory because each service is independent. Tests run against the dev compose stack (`docker-compose.dev.yml`), which provides all real dependencies (PostgreSQL, storage volumes, etc.).

### Test Database Strategy

**Use the real database, not a substitute.** The dev compose includes a local PostgreSQL container — tests connect to it directly. Do not introduce SQLite, H2, or other stand-ins for the production database engine.

- Tests use the same PostgreSQL that the service runs against in development
- Each test gets a transaction that rolls back after the test completes (no leftover state)
- The `conftest.py` `db` fixture wraps each test in `session.begin_nested()` / `session.rollback()`
- Only mock external services that are expensive or unavailable locally (e.g., ML model inference, cloud APIs)

**Why:** Substituting a different database engine introduces false passes — queries that work in SQLite may fail in PostgreSQL and vice versa. The dev compose already provides PostgreSQL at zero extra effort.

### Test Categories

Every service must have at minimum:

**1. Import/compile tests** — The code loads without errors

```python
def test_app_imports():
    from app.main import app
    assert app is not None
```

**2. Contract tests** — Inputs and outputs match the spec

```python
def test_health_returns_expected_shape(client):
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert "status" in data
    assert "service" in data
    assert "checks" in data

def test_upload_rejects_oversized_file(client):
    big_file = b"x" * (26 * 1024 * 1024)  # 26 MB
    response = client.post("/voice-messages", files={"file": ("big.wav", big_file)})
    assert response.status_code == 400
    assert "error" in response.json()
```

**3. Command/output tests** — Operations produce expected results

```python
def test_upload_creates_pending_message(client, db):
    response = client.post("/voice-messages", files={"file": ("test.wav", audio_bytes)})
    assert response.status_code == 202
    data = response.json()
    assert data["status"] == "pending"
    assert "id" in data

    # Verify DB state
    msg = db.query(VoiceMessage).filter_by(id=data["id"]).first()
    assert msg is not None
    assert msg.status == "pending"
```

### Running Tests

Tests require the dev compose stack to be running (for PostgreSQL and other dependencies):

**Python services:**

```bash
# Start the dev stack (if not already running)
docker compose -f docker-compose.dev.yml up -d

# Run tests from the service directory
docker compose -f docker-compose.dev.yml exec {service} pytest tests/ -v
```

**Go services:**

```bash
go test ./... -v
```

### Test Dependencies

Add test dependencies to `requirements.txt` under a comment block:

```
# Application
fastapi==0.115.6
uvicorn[standard]==0.34.0
...

# Testing
pytest==8.3.4
httpx==0.28.1
```

### What NOT to test

- Don't test framework behavior (FastAPI routing works, SQLAlchemy commits work)
- Don't test third-party libraries
- Don't write tests that only pass with a specific database state
- Don't mock the database — use the real PostgreSQL from dev compose
- Don't introduce test-only database engines (SQLite, H2) — use the same tools already in the stack

---

## .gitignore

### Standard entries for all projects

```gitignore
# Environment and secrets
.env
.env.local
.env.*.local

# Python
__pycache__/
*.py[cod]
*.egg-info/
.venv/
dist/
build/

# Go
/bin/

# Node.js
node_modules/
dist/

# IDE
.vscode/
.idea/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Docker
docker-compose.override.yml
```

Rules:
- `.env` is always ignored (secrets never committed)
- Build artifacts are always ignored
- IDE config is always ignored (personal preference, not project config)
- `docker-compose.override.yml` is ignored (local-only compose customizations)

---

## Environment Variables

### Naming

- Uppercase, underscore-separated: `DB_USER`, `WHISPER_MODEL`
- Prefixed by scope when ambiguous: `AWS_ACCESS_KEY_ID`, `S3_BUCKET_NAME`

### Required Variables

| Variable | Used By | Example |
|----------|---------|---------|
| `DB_USER` | Server, Transcriber | `aspirant_user` |
| `DB_PASSWORD` | Server, Transcriber | `secure-password` |
| `DB_NAME` | Server, Transcriber | `aspirant_online_db` |
| `DB_HOST` | Server, Transcriber | `postgres` (Docker) / `localhost` (local) |
| `AWS_ACCESS_KEY_ID` | Server | AWS key |
| `AWS_SECRET_ACCESS_KEY` | Server | AWS secret |
| `AWS_REGION` | Server | `us-east-1` |
| `S3_BUCKET_NAME` | Server | `aspirant-bucket` |
| `WHISPER_MODEL` | Transcriber | `base` |
| `AUDIO_STORAGE_PATH` | Transcriber | `/data/audio` |

### `.env` File

- Lives at project root, never committed
- `.env.example` is committed as a template
- Secrets are never baked into Docker images (passed at runtime via `env_file`)

---

## Documentation

### File Naming

| Document | Filename | Location |
|----------|----------|----------|
| Spec | `{PROJECT}_SPEC.md` | `docs/` |
| Architecture | `{PROJECT}_ARCHITECTURE.md` | `docs/` |
| Changelog | `CHANGELOG.md` | `docs/` |
| Operations | `{PROJECT}_OPERATIONS.md` | `docs/` |
| Decisions | `DECISIONS.md` | `docs/` |
| Style guide | `STYLE_GUIDE.md` | `docs/` |
| README | `README.md` | repo root |

Templates for all of these are in the [_template/](_template/) directory.

### Diagrams

- Prefer ASCII box-and-arrow for simple layouts (portable, no tooling needed)
- Use Mermaid for complex flows (renders on GitHub)
- Always label connections with protocol/port
- Include a legend if using colors or shapes

---

## CI/CD

### GitHub Actions

- Workflow file: `.github/workflows/ci.yml`
- Triggers: push to `main`, pull requests to `main`
- Two jobs: `test` (runs on every push/PR) and `build-and-push` (runs on `main` only, after tests pass)
- Secrets managed in GitHub repo settings (GHCR auth uses the built-in `GITHUB_TOKEN`)
- Reference template: `_template/.github/workflows/ci.yml`

### New Service CI Setup

Every service that has a Docker image in `docker-compose.yml` **must** have a CI workflow. Without it, the image will never be built and production will fail with a pull error.

1. Create `.github/workflows/ci.yml` with test and build jobs (see variants below)
2. Merge to main — this triggers the first image push to ghcr.io
3. Set the ghcr.io package to **public** — new packages default to private. Go to `https://github.com/users/{owner}/packages/container/{package}/settings` → Danger Zone → Change visibility → Public
4. Verify: `docker pull ghcr.io/{owner}/{repo}:latest` should work without authentication

### Docker Image Safety

- **Always create `.dockerignore`** — exclude `.git`, `.env`, `__pycache__/`, test data, and any sensitive files
- **Never bake personal or sensitive data into images** — seed files, configuration with personal patterns, raw data must be mounted as volumes at runtime, not `COPY`'d in the Dockerfile
- **ARM Mac compatibility** — CI runners build amd64 images; add `platform: linux/amd64` to the service in `docker-compose.yml` for local testing on ARM Macs

### Workflow Structure

Every service follows the same two-job pattern:

```
test → build-and-push (main only)
```

1. **test** — runs on every push and pull request to `main`
2. **build-and-push** — runs only on `main` after tests pass; builds the Docker image and pushes to GHCR

### Test Job Variants

The test job differs by service type. Pick the variant that matches your service.

#### Python + Database (transcriber, commander, finance)

Services that depend on PostgreSQL use a GitHub Actions service container:

```yaml
test:
  runs-on: ubuntu-latest
  services:
    postgres:
      image: postgres:16-alpine
      env:
        POSTGRES_USER: test_user
        POSTGRES_PASSWORD: test_password
        POSTGRES_DB: test_db
      ports:
        - 5432:5432
      options: >-
        --health-cmd pg_isready
        --health-interval 10s
        --health-timeout 5s
        --health-retries 5
  steps:
  - uses: actions/checkout@v4
  - name: Build test image
    run: docker build -t test-image .
  - name: Run tests
    run: |
      docker run --rm --network host \
        -e DB_HOST=localhost \
        -e DB_USER=test_user \
        -e DB_PASSWORD=test_password \
        -e DB_NAME=test_db \
        -v "$(pwd)/tests:/app/tests" \
        test-image pytest tests/ -v
```

#### Python Stateless (translator, remarkable, monitor)

Services without a database dependency use `setup-python` directly:

```yaml
test:
  runs-on: ubuntu-latest
  steps:
  - uses: actions/checkout@v4
  - name: Set up Python
    uses: actions/setup-python@v5
    with:
      python-version: '3.11'
  - name: Install test dependencies
    run: pip install -r requirements-test.txt
  - name: Run tests
    run: pytest tests/ -v
```

If no `requirements-test.txt` exists, install from `requirements.txt` instead.

#### Go (server)

```yaml
test:
  runs-on: ubuntu-latest
  steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-go@v5
    with:
      go-version: "1.23"
  - run: go test ./...
```

#### Vue (client)

The client has no test job — only a build-and-push job triggered on push to `main`.

### Build-and-Push Job

Identical across all services (except client, which skips the `needs: test` gate):

```yaml
build-and-push:
  runs-on: ubuntu-latest
  needs: test
  if: github.ref == 'refs/heads/main'
  permissions:
    contents: read
    packages: write
  steps:
  - uses: actions/checkout@v4
  - uses: docker/setup-buildx-action@v3
  - uses: docker/login-action@v3
    with:
      registry: ghcr.io
      username: ${{ github.actor }}
      password: ${{ secrets.GITHUB_TOKEN }}
  - name: Extract metadata
    id: meta
    uses: docker/metadata-action@v5
    with:
      images: ghcr.io/${{ github.repository }}
      tags: |
        type=ref,event=branch
        type=sha
        type=raw,value=latest,enable={{is_default_branch}}
  - name: Build and push
    uses: docker/build-push-action@v5
    with:
      context: .
      file: ./Dockerfile
      push: true
      tags: ${{ steps.meta.outputs.tags }}
      labels: ${{ steps.meta.outputs.labels }}
      cache-from: type=gha
      cache-to: type=gha,mode=max
```

### Image Tagging

Use `docker/metadata-action@v5` for consistent tags on every push to `main`:

| Tag | Example | Purpose |
|-----|---------|---------|
| `main` | `ghcr.io/.../aspirant-transcriber:main` | Latest from main branch |
| `sha-<7char>` | `ghcr.io/.../aspirant-transcriber:sha-a1b2c3d` | Immutable per commit |
| `latest` | `ghcr.io/.../aspirant-transcriber:latest` | Default pull tag |

All three tags are produced by the metadata-action `tags` config shown above. Deploy pulls `latest`.

### Caching

Use GitHub Actions cache with buildx to speed up builds:

```yaml
cache-from: type=gha
cache-to: type=gha,mode=max
```

Requires `docker/setup-buildx-action@v3` in the build job.

### Deployment

```bash
ssh aspirant
cd ~/aspirant-deploy
docker compose pull
docker compose up -d --force-recreate
```

No blue/green, no rolling updates — pull and restart. Acceptable for a single-user home server.

