# Project Template

Skeleton files for starting a new service. Copy this directory, replace all `{placeholders}`, and fill in each section.

## Usage

1. Copy `_template/` contents into your new service directory
2. Replace all `{placeholders}` with real values
3. Fill in the spec and architecture docs before writing code
4. Allocate a port in [INFRASTRUCTURE.md](../INFRASTRUCTURE.md)
5. Follow [CONVENTIONS.md](../CONVENTIONS.md) for naming, API patterns, testing, and logging
6. Delete this README after setup

## Files

| File | Purpose | Reference |
|------|---------|-----------|
| `docs/SPEC.md` | What we're building and why | [Philosophy → Spec-Driven Development](../DEVELOPMENT_PHILOSOPHY.md#spec-driven-development) |
| `docs/ARCHITECTURE.md` | How it fits together (with diagrams) | [Philosophy → Architecture File](../DEVELOPMENT_PHILOSOPHY.md#architecture-file) |
| `docs/CHANGELOG.md` | Timestamped record of changes | [Philosophy → Changelog](../DEVELOPMENT_PHILOSOPHY.md#changelog) |
| `docs/DECISIONS.md` | Why key choices were made | [Philosophy → Required Artifacts](../DEVELOPMENT_PHILOSOPHY.md#required-artifacts) |
| `docs/OPERATIONS.md` | Setup, run, test, validate, debug, gotchas | [Philosophy → Documentation Standards](../DEVELOPMENT_PHILOSOPHY.md#documentation-standards) |
| `app/` | Python service source (FastAPI skeleton) | [Conventions → Python Services](../CONVENTIONS.md#python-services) |
| `tests/` | Test suite (pytest skeleton) | [Conventions → Testing](../CONVENTIONS.md#testing) |

## Checklist

Before starting implementation:

- [ ] SPEC.md reviewed and approved
- [ ] ARCHITECTURE.md has a system context diagram
- [ ] Port allocated in INFRASTRUCTURE.md
- [ ] Volume named (if needed) in CONVENTIONS.md
- [ ] Docker Compose entries planned for both `docker-compose.yml` and `docker-compose.dev.yml`
- [ ] Health endpoint follows the standard contract (CONVENTIONS.md → API Contract)
- [ ] Logging uses the standard format (CONVENTIONS.md → Logging)

After implementation:

- [ ] Tests pass (`pytest tests/ -v`)
- [ ] INFRASTRUCTURE.md updated with new service details
- [ ] CHANGELOG.md has an entry for today
- [ ] DECISIONS.md has entries for non-obvious choices
- [ ] OPERATIONS.md gotchas section filled in

### Deployment (must complete before service goes live)

- [ ] **CI workflow created** — `.github/workflows/ci.yml` with test + build + push jobs (see CONVENTIONS.md → CI/CD)
- [ ] **`.dockerignore` created** — exclude `.git`, `.env`, `__pycache__`, test data, and any personal/sensitive files
- [ ] **No sensitive data in Docker image** — seed files, config with personal data, raw data directories must NOT be `COPY`'d into the Dockerfile; mount as volumes instead
- [ ] **CI runs successfully on main** — merge a commit to main, verify the image is built and pushed to ghcr.io
- [ ] **ghcr.io package set to public** — new packages default to private; go to `https://github.com/users/{owner}/packages/container/{package}/settings` and change visibility to public
- [ ] **`platform: linux/amd64`** — add to the service in `docker-compose.yml` if the CI only builds amd64 (required for ARM Mac testing)
- [ ] **Seed data volume** — if the service needs initialization files, mount them as a read-only volume in compose rather than baking into the image; copy files to `/data/aspirant/{service}/` on the production server
- [ ] **`docker compose pull {service}`** — verify the image pulls successfully without auth
- [ ] **`docker compose up -d {service}`** — verify the service starts and passes health check
