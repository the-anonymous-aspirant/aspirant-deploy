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
| `.github/workflows/ci.yml` | CI: test + build-and-push to GHCR | [Conventions → CI/CD](../CONVENTIONS.md#cicd) |

## Checklist

Before starting implementation:

- [ ] SPEC.md reviewed and approved
- [ ] ARCHITECTURE.md has a system context diagram
- [ ] Port allocated in INFRASTRUCTURE.md
- [ ] Volume named (if needed) in CONVENTIONS.md
- [ ] Docker Compose entries planned for both `docker-compose.yml` and `docker-compose.dev.yml`
- [ ] CI/CD workflow entry planned
- [ ] Health endpoint follows the standard contract (CONVENTIONS.md → API Contract)
- [ ] Logging uses the standard format (CONVENTIONS.md → Logging)

After implementation:

- [ ] Tests pass (`pytest tests/ -v`)
- [ ] CI workflow adapted from template (pick correct test variant from CONVENTIONS.md → CI/CD)
- [ ] INFRASTRUCTURE.md updated with new service details
- [ ] CHANGELOG.md has an entry for today
- [ ] DECISIONS.md has entries for non-obvious choices
- [ ] OPERATIONS.md gotchas section filled in
