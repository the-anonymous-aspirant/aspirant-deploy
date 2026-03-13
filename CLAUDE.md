# CLAUDE.md

## About

This is the central hub for the Aspirant platform — deployment configuration, development conventions, infrastructure inventory, and project templates. It contains no application code.

## What's Here

| File/Dir | Purpose |
|----------|---------|
| `docker-compose.yml` | Production deployment (pre-built GHCR images) |
| `docker-compose.dev.yml` | Local development (builds from sibling repos) |
| `CONVENTIONS.md` | Naming, API contracts, logging, testing, Docker, Git, database rules |
| `DEVELOPMENT_PHILOSOPHY.md` | Values, principles, spec-driven lifecycle |
| `INFRASTRUCTURE.md` | Deployed services, ports, tables, volumes, DNS |
| `_template/` | Skeleton files for scaffolding a new service |
| `.env.example` | Environment variable template |
| `docs/` | Platform-wide architecture, operations, decisions, changelog |
| `tests/integration.sh` | Cross-service integration tests |

## Before You Start

Read these in order:
1. **This file** — repo layout and commands
2. **DEVELOPMENT_PHILOSOPHY.md** — values and the 6-phase lifecycle (spec → architecture → plan → implement → verify → ship)
3. **CONVENTIONS.md** — the rulebook for API shape, logging, testing, naming, Docker patterns
4. **INFRASTRUCTURE.md** — current state of all deployed services, ports, tables, volumes

**Conventions are the source of truth, not existing code.** Some services may predate current standards. Always follow CONVENTIONS.md.

## Services

| Service | Repo | Port | Type |
|---------|------|------|------|
| PostgreSQL | (standard image) | 5432 | Database |
| Server | `../aspirant-server` | 8081→8080 | Go/Gin |
| Client | `../aspirant-client` | 80 | Vue.js/Nginx |
| Transcriber | `../aspirant-transcriber` | 8082→8000 | Python/FastAPI |
| Commander | `../aspirant-commander` | 8083→8000 | Python/FastAPI |
| Translator | `../aspirant-translator` | 8084→8000 | Python/FastAPI |
| Monitor | `../aspirant-monitor` | 8085→8000 | Python/FastAPI |
| Remarkable | `../aspirant-remarkable` | 8086→8000 | Python/FastAPI |
| Finance | `../aspirant-finance` | 8087→8000 | Python/FastAPI |
| Kiwix | (3rd party image) | internal 8080 | kiwix-serve |

## Adding a New Service

1. **Scaffold:** `cp -r _template/ ../aspirant-{name}/` — gives you app/, tests/, docs/ skeletons
2. **Allocate:** Check INFRASTRUCTURE.md for next port (currently 8088), reserve tables/volumes
3. **Spec first:** Fill in `docs/SPEC.md` and `docs/ARCHITECTURE.md` before writing code
4. **Implement:** Follow CONVENTIONS.md (health endpoint, logging format, test categories)
5. **Compose:** Add the service to both `docker-compose.yml` and `docker-compose.dev.yml`
6. **Validate:** Run `python -m app.main scan ../aspirant-{name}` from aspirant-auditor
7. **Update:** Add service details to INFRASTRUCTURE.md, log decisions in docs/DECISIONS.md
8. **Ship:** Create GitHub repo, set up CI, push, PR compose changes, deploy

See `_template/README.md` for the full pre/post-implementation checklist.

## Common Commands

```bash
# Production
docker compose pull && docker compose up -d --force-recreate

# Development (requires sibling repos)
docker compose -f docker-compose.dev.yml up -d

# Logs
docker compose logs -f <service>

# Health checks
curl localhost:8081/health   # server
curl localhost:8082/health   # transcriber
curl localhost:8083/health   # commander
curl localhost:8084/health   # translator
curl localhost:8085/health   # monitor
curl localhost:8086/health   # remarkable
curl localhost:8087/health   # finance

# Integration tests
./tests/integration.sh

# Convention auditor (from aspirant-auditor repo)
python -m app.main scan-all ~/git/
```

## Important

- Never commit `.env` — it contains credentials
- Never commit directly to `main` — use feature branches
- Dev compose runs PostgreSQL on port 5433 (not 5432) to avoid conflicts
- Dev volumes are separate (`pgdata-dev`) so dev data never mixes with production
- Always use `--force-recreate` when deploying new images
- Always restart the client container when restarting backend services (Nginx caches DNS)
