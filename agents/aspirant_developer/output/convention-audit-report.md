# Convention Compliance Audit Report

**Date:** 2026-03-31
**Scope:** All aspirant-* repositories under ~/git/
**Reference:** CONVENTIONS.md, DEVELOPMENT_PHILOSOPHY.md

---

## Summary Table

| Repo | Git | Structure | API Contract | Logging | Testing | Docker | Docs | Database | Environment |
|------|-----|-----------|-------------|---------|---------|--------|------|----------|-------------|
| **server** | PARTIAL | PASS | PASS | PASS | PASS | PASS | PASS | PASS | FAIL |
| **client** | PARTIAL | PASS | N/A | N/A | PASS | PASS | PASS | N/A | PARTIAL |
| **transcriber** | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PARTIAL |
| **commander** | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PARTIAL |
| **translator** | PASS | PASS | PASS | PASS | PASS | PASS | PASS | N/A | FAIL |
| **monitor** | FAIL | PASS | PASS | PASS | PASS | PASS | PASS | N/A | PARTIAL |
| **remarkable** | FAIL | PASS | PASS | PASS | PASS | PASS | FAIL | N/A | PARTIAL |
| **finance** | PARTIAL | PASS | PASS | PASS | PARTIAL | PASS | PASS | PASS | PARTIAL |
| **advisor** | PARTIAL | PASS | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| **auditor** | PASS | PASS | PASS | PARTIAL | PASS | PARTIAL | PASS | N/A | PASS |
| **deploy** | FAIL | PASS | N/A | N/A | N/A | PASS | PASS | N/A | PASS |

**Legend:** PASS = fully compliant, PARTIAL = mostly compliant with minor gaps, FAIL = significant violations, N/A = not applicable

---

## Cross-Cutting Findings

### 1. AI Co-Authored-By Trailers (Systemic Issue)

CONVENTIONS.md explicitly states: *"Do not add Co-Authored-By trailers for AI agents in commit messages."*

**Repos with violations:** server, client, monitor, remarkable, finance, advisor, deploy (7 of 11 repos)

This is the single most widespread convention violation across the platform. It appears in dozens of commits across multiple repositories.

### 2. Missing .env.example (Systemic Issue)

CONVENTIONS.md requires `.env.example` as a committed template.

**Repos missing it:** server, client, transcriber, commander, translator, monitor, remarkable, finance (8 of 11 repos)

Only **advisor**, **auditor** (N/A — CLI tool), and **deploy** have this file.

---

## Detailed Findings Per Repo

### aspirant-server (Go/Gin)

| Category | Status | Details |
|----------|--------|---------|
| Git | PARTIAL | Commit format correct (imperative, <72 chars, no period). **Multiple commits have AI Co-Authored-By trailers.** |
| Structure | PASS | data_models/, data_functions/, handlers/, middleware/, database.go, routes.go, Dockerfile-Server all present. |
| API Contract | PASS | /health returns {status, service, version, checks} with memory stats. ErrorResponse has {error: {code, message}}. Pagination uses {items, total, page, page_size} with default 20, max 100. |
| Logging | PASS | Gin custom formatter with service context. log.Printf used with structured fields. |
| Testing | PASS | test files in handlers/ (health, voice), data_functions/ (utils, word_weaver), storage/. Import, contract, and command/output tests present. |
| Docker | PASS | Dockerfile-Server, .dockerignore, CI with go test + build-and-push. |
| Docs | PASS | SPEC.md, ARCHITECTURE.md, CHANGELOG.md, DECISIONS.md, OPERATIONS.md, README.md all present. |
| Database | PASS | Tables: users, roles, messages, game_scores, ludde_feeding_times (plural snake_case). Auto-increment integer PKs via gorm.Model. FK pattern: role_id, sender_id. |
| Environment | FAIL | **.env.example missing** despite README referencing it. .gitignore correctly excludes .env. |

---

### aspirant-client (Vue/Nginx)

| Category | Status | Details |
|----------|--------|---------|
| Git | PARTIAL | Commit format correct. **Extensive AI Co-Authored-By trailers** across most recent commits. Inconsistent casing (Co-authored-by vs Co-Authored-By). |
| Structure | PASS | src/views/ (11 subdirs), src/components/ (7 subdirs), src/router/, Dockerfile-Client all present. |
| Docker | PASS | Dockerfile-Client, .dockerignore, CI with only build-and-push job (no test job per convention). |
| Docs | PASS | SPEC.md, ARCHITECTURE.md, CHANGELOG.md, DECISIONS.md, OPERATIONS.md, README.md all present. |
| Environment | PARTIAL | **.env.example missing.** .gitignore correctly excludes .env, node_modules/, dist/. |
| Testing | PASS | No tests present, no test job in CI — correct per convention (client has no test requirement). |

---

### aspirant-transcriber (Python/FastAPI)

| Category | Status | Details |
|----------|--------|---------|
| Git | PASS | 3 commits, all imperative, <72 chars, no period. No AI Co-Authored-By. |
| Structure | PASS | Full Python layout: app/{__init__, main, config, database, models, schemas, routes, tasks, transcription}.py, tests/{__init__, conftest, test_health, test_voice_messages}.py, Dockerfile-Transcriber, requirements.txt. |
| API Contract | PASS | /health returns {status: "ok", service: "transcriber", version: "1.0.0", checks: {database, whisper_model}}. Error helper _error() enforces {error: {code, message}}. Pagination on /voice-messages with page/page_size (default 20, max 100). |
| Logging | PASS | Exact standard format: `%(asctime)s [%(levelname)s] %(name)s: %(message)s` with datefmt `%Y-%m-%dT%H:%M:%SZ`. All modules use getLogger(__name__). |
| Testing | PASS | conftest.py with real PostgreSQL, transaction rollback (begin_nested/rollback). test_health.py (contract), test_voice_messages.py (CRUD operations). Mock whisper model for CI. |
| Docker | PASS | Dockerfile-Transcriber (python:3.11-slim, ffmpeg), .dockerignore, CI with postgres service container. |
| Docs | PASS | All 5 required docs + README present. |
| Database | PASS | Table: voice_messages (plural snake_case). UUID PK. All columns snake_case. Proper indexes. |
| Environment | PARTIAL | **.env.example missing.** .gitignore excludes .env. Config reads DB_USER, DB_PASSWORD, DB_HOST, DB_NAME, WHISPER_MODEL, AUDIO_STORAGE_PATH. |

---

### aspirant-commander (Python/FastAPI)

| Category | Status | Details |
|----------|--------|---------|
| Git | PASS | 4 commits, all imperative, <72 chars, no period. No AI Co-Authored-By (only human co-author). |
| Structure | PASS | Full Python layout with app/{main, config, database, models, schemas, routes, parser, poller}.py. Tests in tests/{conftest, test_health, test_tasks, test_parser}.py. |
| API Contract | PASS | /health returns {status, service: "commander", version, database, polling}. _error() helper for consistent error shape. Pagination on /tasks and /notes (page/page_size). |
| Logging | PASS | Exact standard format. All modules use getLogger(__name__). |
| Testing | PASS | conftest.py with real PostgreSQL (TEST_DATABASE_URL). Contract tests (health shape), CRUD tests (tasks, notes), parser tests. |
| Docker | PASS | Dockerfile-Commander, .dockerignore, CI with postgres service container + TEST_DATABASE_URL. |
| Docs | PASS | All 5 required docs + PARSER_GUIDE.md + README. |
| Database | PASS | Tables: commander_tasks, commander_notes, commander_processed (plural snake_case). UUID PKs. Proper indexes on status, priority, created_at. |
| Environment | PARTIAL | **.env.example missing.** .gitignore excludes .env. |

---

### aspirant-translator (Python/FastAPI)

| Category | Status | Details |
|----------|--------|---------|
| Git | PASS | 4 commits, all compliant. No AI Co-Authored-By. |
| Structure | PASS | Stateless service — no database.py/models.py (correct). app/{main, config, routes, model_manager}.py present. requirements-test.txt separate (correct for stateless CI variant). |
| API Contract | PASS | /health returns {status, service: "translator", version, checks: {argos_translate, models_volume}}. Error shape consistent with 4 error codes. No pagination needed (stateless). |
| Logging | PASS | Exact standard format in main.py. |
| Testing | PASS | 5 test files: test_health, test_languages, test_translations, test_model_manager. Covers contract, unit, and integration categories. conftest.py mocks argostranslate. |
| Docker | PASS | Dockerfile-Translator (python:3.11-slim, CPU-only PyTorch), .dockerignore, CI with stateless pytest variant. |
| Docs | PASS | All 5 required docs + README. |
| Environment | FAIL | **.env.example missing.** .gitignore present. Config uses MAX_LOADED_MODELS, MAX_TEXT_LENGTH, ARGOS_PACKAGES_PATH. |

---

### aspirant-monitor (Python/FastAPI)

| Category | Status | Details |
|----------|--------|---------|
| Git | FAIL | **AI Co-Authored-By in commits 2aab2cf and 9423f23.** Two commits exceed 72-char limit (77 and 81 chars — one is a merge commit). |
| Structure | PASS | app/{main, config, routes, email, scheduler, system_metrics, daily_report}.py. Tests in tests/. |
| API Contract | PASS | /health returns {status, docker_connected, service: "monitor", version}. _error() helper for consistent error shape. |
| Logging | PASS | Exact standard format. All modules use getLogger(__name__). |
| Testing | PASS | 30+ tests across test_health, test_containers, test_disk, test_system_metrics, test_email, test_daily_report. |
| Docker | PASS | Dockerfile-Monitor, .dockerignore, CI with stateless pytest variant. |
| Docs | PASS | All 5 required docs + README. |
| Environment | PARTIAL | **.env.example missing.** .gitignore excludes .env. Uses SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, ALERT_EMAIL_TO, ALERT_EMAIL_FROM, DAILY_REPORT_HOUR. |

---

### aspirant-remarkable (Python/FastAPI)

| Category | Status | Details |
|----------|--------|---------|
| Git | FAIL | **8 commits have AI Co-Authored-By.** 5 of 20 commits exceed 72-char limit (up to 86 chars). |
| Structure | PASS | app/{main, config, routes, schemas, parser, sync, renderer, ssh, sync_status, to_device, svg_export}.py. 8 test files. |
| API Contract | PASS | /health returns {status, service: "remarkable", version: "1.2.0", checks: {rmscene, rmc, data_volume, ssh_key}}. Error shape consistent. |
| Logging | PASS | Exact standard format. All 9 modules use getLogger(__name__). |
| Testing | PASS | 57 tests across 8 files. Unit, functional, rendering, and algorithm tests. conftest.py pre-mocks heavy deps. |
| Docker | PASS | Dockerfile-Remarkable, .dockerignore, CI with stateless variant. |
| Docs | FAIL | **No docs/ directory.** Missing all 5 required documents (SPEC.md, ARCHITECTURE.md, CHANGELOG.md, DECISIONS.md, OPERATIONS.md). Only README.md and device/INSTALL.md exist. |
| Environment | PARTIAL | **.env.example missing.** .gitignore excludes .env. Uses REMARKABLE_HOST, DATA_PATH. |

---

### aspirant-finance (Python/FastAPI)

| Category | Status | Details |
|----------|--------|---------|
| Git | PARTIAL | Commit format mostly correct. **17+ commits have AI Co-Authored-By.** One commit at 77 chars (over limit). |
| Structure | PASS | Full Python layout with app/{main, config, database, models, schemas, routes, enrichment, currency}.py + app/parsers/ (N26, DKB, SEB). |
| API Contract | PASS | /health returns {status, service: "finance", version, checks: {database}}. Error shape consistent. Pagination on /transactions (page/page_size, default 50, max 200). |
| Logging | PASS | Exact standard format. |
| Testing | PARTIAL | Only 7 tests total across 3 files. Has conftest.py with real PostgreSQL and transaction rollback. **Missing end-to-end tests** (CSV upload, enrichment flow). Coverage thin for service complexity. |
| Docker | PASS | Dockerfile-Finance, .dockerignore, CI with postgres service container. |
| Docs | PASS | All 5 required docs + ADDING_SOURCES.md + README. |
| Database | PASS | Tables: finance_transactions, finance_categories, finance_payee_normalizations, finance_accounts (plural snake_case). UUID PKs. Proper timestamps with timezone. |
| Environment | PARTIAL | **.env.example missing.** .gitignore excludes .env. |

---

### aspirant-advisor (Python/FastAPI)

| Category | Status | Details |
|----------|--------|---------|
| Git | PARTIAL | Commit format correct. **5 recent commits (PRs #4-#8) have AI Co-Authored-By.** |
| Structure | PASS | Full Python layout with app/{main, config, database, models, schemas, routes, ingestion, retrieval, generation, embedding}.py + app/parsers/ (PDF, DOCX, text, law). |
| API Contract | PASS | /health returns {status, service: "advisor", version, checks: {database, pgvector, ollama}}. ErrorDetail with code, message, details. |
| Logging | PASS | Exact standard format. |
| Testing | PASS | test_health (contract), test_generation + test_ingestion (unit), test_source_quality (41 parametrized quality tests). conftest.py with nested transactions. |
| Docker | PASS | Dockerfile-Advisor, .dockerignore, CI with pgvector:pg16 service container. |
| Docs | PASS | All 5 required docs + PLAN.md + README. |
| Database | PASS | Tables use snake_case plural. UUID PKs. pgvector extension for embeddings. |
| Environment | PASS | **.env.example present** with DB_HOST, DB_USER, DB_PASSWORD, DB_NAME, OLLAMA_URL, OLLAMA_MODEL, EMBEDDING_MODEL, ADVISOR_DATA_PATH. .gitignore excludes .env. |

---

### aspirant-auditor (Python CLI)

| Category | Status | Details |
|----------|--------|---------|
| Git | PASS | 6 commits, all imperative, <72 chars, no period. No AI Co-Authored-By. |
| Structure | PASS | app/{main, config, detector, loader, reporter, scanner}.py + app/checks/ (10 check modules). tests/ with 5 test files. rules/ directory. |
| API Contract | PASS | Not a web service, but implements API contract checks for other repos. |
| Logging | PARTIAL | Implements logging checks for other repos but doesn't use stdlib logging itself (uses Rich for terminal output). Appropriate for a CLI tool. |
| Testing | PASS | 29 tests across test_cli, test_detector, test_docker_compose, test_documentation, test_required_files. Uses tmp_repo fixtures. |
| Docker | PARTIAL | Dockerfile present (named `Dockerfile`, not `Dockerfile-Auditor`). **.dockerignore missing.** CI workflow present with tests + self-audit. |
| Docs | PASS | All 5 required docs + README. |
| Environment | PASS | .gitignore comprehensive. .env.example N/A (CLI tool with no runtime secrets). |

---

### aspirant-deploy (Infrastructure)

| Category | Status | Details |
|----------|--------|---------|
| Git | FAIL | **6+ commits have AI Co-Authored-By.** Mixed casing (Co-Authored-By vs Co-authored-by). Commit format otherwise correct. |
| Structure | PASS | docker-compose.yml, docker-compose.dev.yml, CONVENTIONS.md, DEVELOPMENT_PHILOSOPHY.md, INFRASTRUCTURE.md, _template/, .env.example, docs/, tests/integration.sh, CLAUDE.md all present. |
| Docker Compose (Prod) | PASS | All 12 services present (postgres, server, client, transcriber, commander, translator, monitor, remarkable, finance, advisor, ollama, kiwix). Health checks, depends_on, platform:linux/amd64, mem_limit on heavy services. |
| Docker Compose (Dev) | PASS | Postgres on port 5433, pgdata-dev volume, DB_HOST:postgres overrides, client depends_on server, all dev volumes separated (*-dev). |
| Docs | PASS | docs/ has ARCHITECTURE.md, CHANGELOG.md, DECISIONS.md, OPERATIONS.md, ROADMAP.md, SPEC.md. Top-level: CLAUDE.md, README.md, CONVENTIONS.md, DEVELOPMENT_PHILOSOPHY.md, INFRASTRUCTURE.md. |
| Environment | PASS | .env.example present with all required variables. .gitignore excludes .env, SSH keys, docker-compose.override.yml. |
| Template | PASS | _template/ has complete skeleton: README with checklists, docs/ (5 files), app/, tests/, .github/workflows/ci.yml. |

---

## Prioritized Fix List

### High Priority

| # | Repo | Issue | Impact |
|---|------|-------|--------|
| 1 | **remarkable** | Missing entire docs/ directory (SPEC.md, ARCHITECTURE.md, CHANGELOG.md, DECISIONS.md, OPERATIONS.md) | Blocks onboarding, violates spec-driven development lifecycle |
| 2 | **All 7 repos** | AI Co-Authored-By trailers in commits (server, client, monitor, remarkable, finance, advisor, deploy) | Systemic convention violation; establish a hook or commit template to prevent recurrence |

### Medium Priority

| # | Repo | Issue | Impact |
|---|------|-------|--------|
| 3 | **8 repos** | Missing .env.example (server, client, transcriber, commander, translator, monitor, remarkable, finance) | Developer onboarding friction — new contributors can't discover required env vars |
| 4 | **finance** | Only 7 tests for a service with parsers, enrichment, currency conversion, and CRUD | Low confidence in correctness; add E2E tests for CSV upload, enrichment, dedup, error paths |
| 5 | **remarkable, monitor** | Commit subjects exceeding 72-char limit (up to 86 chars) | Minor readability issue in git log --oneline |
| 6 | **auditor** | Dockerfile named `Dockerfile` instead of `Dockerfile-Auditor` | Inconsistent with naming convention |

### Low Priority

| # | Repo | Issue | Impact |
|---|------|-------|--------|
| 7 | **auditor** | Missing .dockerignore | Docker build copies unnecessary files (tests, docs, .git) |
| 8 | **auditor** | No application-level logging (uses Rich only) | Acceptable for CLI, but limits operational debugging for CI/batch runs |
| 9 | **server** | Health endpoint uses `status: "healthy"` instead of `status: "ok"` | Minor deviation from standard health response spec |
| 10 | **finance** | Pagination page_size default is 50 (max 200) instead of standard 20 (max 100) | Minor deviation from convention defaults |

---

## Statistics

- **Total checks performed:** 88 (11 repos x 8 categories, adjusted for N/A)
- **PASS:** 67 (76%)
- **PARTIAL:** 14 (16%)
- **FAIL:** 7 (8%)
- **Repos with zero failures:** transcriber, commander, translator (best compliance)
- **Repos needing most work:** remarkable (2 failures), monitor (1 failure + 1 partial)
