# Development Philosophy

This document defines the principles, standards, and expectations for all development work — whether done by a human, an AI agent, or both collaborating.

For specific naming patterns, API contracts, and implementation rules, see [CONVENTIONS.md](CONVENTIONS.md). For the current state of deployed services, see [INFRASTRUCTURE.md](INFRASTRUCTURE.md).

---

## Core Values (in priority order)

1. **Simple over complicated** — The best code is the code you don't have to think about. Prefer boring, obvious solutions over clever ones. Three similar lines are better than a premature abstraction.
2. **Slow and reliable over fast but hard to debug** — Performance is a feature, but debuggability is a requirement. When in doubt, choose the approach you can reason about at 2 AM.
3. **Human-readable and comprehensible** — Code is read far more than it is written. Optimize for the next person (or future you) who has to understand it.
4. **Free and open source** — Prefer FOSS tools, libraries, and frameworks. Avoid vendor lock-in. If a proprietary tool is necessary, isolate it behind an interface.
5. **Private by default** — Data stays local unless there's a clear reason to send it elsewhere. Prefer local inference over cloud APIs. Prefer self-hosted over SaaS.
6. **Robust** — Handle failure gracefully. Log clearly. Make the system recoverable without heroics.
7. **Independent and containerized** — New capabilities are built as independent, Dockerized microservices. Each service owns its own code, Dockerfile, and dependencies, and can be built, tested, and deployed in isolation.

---

## Architecture Preference: Independent Microservices

New features that introduce distinct functionality should be built as **separate, containerized services** rather than bolted onto existing ones.

### Why

- **Isolation** — A bug or crash in one service doesn't take down the others
- **Testability** — Each service can be built, started, and tested independently with `docker compose up {service}`
- **Technology freedom** — Use the right tool for the job (Go for the API, Python for ML, etc.) without cross-contaminating dependencies
- **Deployability** — Update one service without rebuilding or restarting the rest
- **Comprehensibility** — A small, focused codebase is easier to understand than a monolith with mixed concerns

### When to create a new service

- The capability has its own data model or storage needs
- It uses a different runtime or significant new dependencies
- It can operate independently (doesn't need to be in the same process as existing code)
- It has a distinct API surface

### When NOT to create a new service

- It's a new endpoint on an existing resource (add it to the existing service)
- It shares the same data model tightly and would require constant cross-service calls
- The overhead of a separate container isn't justified (a 10-line utility doesn't need its own Docker image)

### Service contract

Every microservice must:
1. Have its own directory at the project root (`server/`, `client/`, `transcriber/`, etc.)
2. Have its own Dockerfile (`Dockerfile-{Name}`)
3. Be defined in both `docker-compose.yml` and `docker-compose.dev.yml`
4. Expose a `/health` endpoint
5. Be buildable and runnable with `docker compose up {service}` alone
6. Own its database tables (no two services write to the same table)
7. Work locally without external dependencies — `docker-compose.dev.yml` includes all infrastructure (database, storage) needed to run the full stack on a clean machine

---

## Spec-Driven Development

Every new project, feature, or service starts with documentation — not code.

### Required Artifacts

Every project must produce these artifacts. The first three are created before implementation begins. The changelog and decision log are maintained throughout.

| Artifact | Purpose | Format | Template |
|----------|---------|--------|----------|
| **Spec** | What are we building and why? | `docs/{PROJECT}_SPEC.md` | [_template/docs/SPEC.md](_template/docs/SPEC.md) |
| **Architecture** | How does it fit together? | `docs/{PROJECT}_ARCHITECTURE.md` | [_template/docs/ARCHITECTURE.md](_template/docs/ARCHITECTURE.md) |
| **Development Plan** | What's the order of work? | Numbered steps in the spec or a separate plan file | — |
| **Changelog** | What changed and when? | `docs/CHANGELOG.md` | [_template/docs/CHANGELOG.md](_template/docs/CHANGELOG.md) |
| **Decision Log** | Why were key choices made? | `docs/DECISIONS.md` | [_template/docs/DECISIONS.md](_template/docs/DECISIONS.md) |
| **Operations Guide** | How to run, test, debug? | `docs/{PROJECT}_OPERATIONS.md` | [_template/docs/OPERATIONS.md](_template/docs/OPERATIONS.md) |

### Spec File

The spec is the source of truth. It answers:

- **What** are we building? (scope, endpoints, data model, behavior)
- **Why** are we building it? (motivation, problem statement)
- **What are the constraints?** (resource limits, compatibility, dependencies)
- **What does success look like?** (acceptance criteria, verification steps)

A spec should be detailed enough that someone unfamiliar with the project can understand the intent and scope without reading the code.

### Architecture File

Architecture documentation must prioritize human readability:

- **Prefer diagrams over prose** — A Mermaid diagram or ASCII art box-and-arrow sketch communicates structure faster than paragraphs
- **Show the big picture first** — Start with a system-level view, then zoom into components
- **Label every connection** — Show what flows between components (HTTP, SQL, files, messages)
- **Include port mappings, hostnames, and protocols** — Make it deployable from the diagram alone

Example:
```
┌──────────┐    HTTP     ┌──────────┐    SQL     ┌──────────┐
│  Client   │───────────▶│  Server   │──────────▶│ Postgres  │
│  :80      │            │  :8081    │           │  :5432    │
└──────────┘            └──────────┘           └──────────┘
```

### Development Plan

Before writing code, define the implementation order:

1. Number each step
2. Group by phase if the project is large
3. Note dependencies between steps
4. Include a verification step after each phase

### Changelog

The changelog is a timestamped, human-readable record of what happened:

```markdown
## Changelog

### 2026-03-09
- Initial spec and architecture documents created
- Implemented core API endpoints (upload, list, get, delete)
- Added background transcription with Whisper base model

### 2026-03-10
- Fixed language detection confidence calculation
- Added retry endpoint for failed transcriptions
```

Rules:
- One entry per day of work (group sub-items as bullets)
- Written in past tense
- Describe *what changed*, not *what you did* ("Added retry endpoint" not "I worked on retries")
- Keep it concise — the git log has the details

---

## Code Standards

### Readability

- **Naming matters more than comments** — A well-named function doesn't need a docstring explaining what it does
- **Comments explain *why*, not *what*** — `# Semaphore(1) prevents OOM on 2GB container` is useful; `# increment counter` is noise
- **Flat is better than nested** — Early returns over deep if/else chains
- **Explicit is better than implicit** — Spell out types, defaults, and assumptions

### Simplicity

- **No premature abstraction** — Don't create a factory, registry, or plugin system until you have three concrete cases that need it
- **No speculative features** — Build what's needed now. "We might need this later" is not a reason to build it today
- **Minimal dependencies** — Every dependency is a liability. Prefer standard library. When adding a dependency, it should solve a real problem you can't solve in 20 lines
- **One way to do things** — Avoid offering multiple paths to the same outcome. Pick one and make it obvious

### Robustness

- **Fail loudly, recover gracefully** — Log errors with context. Don't swallow exceptions. But design for restart and retry
- **Validate at boundaries** — Check inputs at the API layer. Trust internal code
- **Idempotent operations where possible** — Retrying an operation shouldn't corrupt state
- **Resource limits everywhere** — Memory limits on containers, file size limits on uploads, timeouts on network calls, semaphores on concurrent work

---

## Testing Philosophy

Testing exists to catch real problems — not to achieve a coverage number. The goal is confidence that the service does what the spec says it does.

### Minimum bar

Every service must have tests that verify three things:

1. **It compiles and starts** — The code imports, the app object is created, dependencies resolve. This catches broken imports, missing packages, and syntax errors before deployment.

2. **Inputs and outputs match the contract** — The API accepts what the spec says it accepts and returns what the spec says it returns. This includes the shape of success responses, error responses, pagination, and the health endpoint. If the spec says "returns 400 for files over 25 MB," there's a test for that.

3. **Commands produce expected results** — CRUD operations actually create, read, update, and delete. A POST followed by a GET returns the thing that was posted. A DELETE followed by a GET returns 404. Background jobs transition through the expected states.

### What testing is NOT here

- It is not chasing 100% code coverage
- It is not mocking every dependency into meaninglessness
- It is not writing tests before the spec is stable (tests codify the spec, not replace it)

### Where tests live

Tests are co-located with the service they test, in a `tests/` directory at the service root. This keeps each service independent — you can run a service's tests without cloning other services.

For specific conventions (file layout, fixtures, running tests), see [CONVENTIONS.md → Testing](CONVENTIONS.md#testing).

---

## Documentation Standards

Every project must include operational documentation covering:

### How to Set Up

- Prerequisites (tools, versions, accounts)
- Step-by-step setup from a clean machine
- Environment variables and secrets (what's needed, where to get them)
- No implicit knowledge — if it's not written down, it doesn't exist

### How to Run

- Development mode (with hot reload if applicable)
- Production mode (Docker Compose or equivalent)
- What ports, URLs, and endpoints become available

### How to Test

- How to run the test suite
- How to manually test key flows (curl examples, sample inputs)
- What "working" looks like (expected outputs, status codes)

### How to Validate

- Health check endpoints and what they verify
- How to confirm the database schema is correct
- How to verify integrations are connected (storage, external services)

### How to Debug

- Where logs are (container logs, file logs, stdout)
- How to inspect state (database queries, API calls)
- How to reproduce common failure modes
- How to attach a debugger or enable verbose logging

### Gotchas

A dedicated section for non-obvious things that will bite you:

- Platform-specific quirks ("Alpine Linux can't compile ML wheels — use slim")
- Timing issues ("Model takes 30s to load on first request")
- Resource constraints ("Whisper base needs ~1 GB RAM; don't run two concurrently")
- Configuration traps ("DB_HOST must be `postgres` in Docker, `localhost` outside")
- Anything that took more than 5 minutes to figure out the first time

---

## AI Agent Expectations

When an AI agent collaborates on any project following these standards:

### Before you start
- Read this document for values and trade-off resolution
- Read [CONVENTIONS.md](CONVENTIONS.md) for naming, API contracts, logging, and test patterns
- Read [INFRASTRUCTURE.md](INFRASTRUCTURE.md) to know what already exists
- **Conventions are the source of truth, not existing code** — Some existing services may predate current standards. Always follow CONVENTIONS.md, even if existing code in the project does it differently. If you notice a discrepancy, flag it

### Planning Phase
- **Start with the spec** — Don't write code until the spec is reviewed and approved
- **Present architecture visually** — Use diagrams, not walls of text
- **Propose a development plan** — Numbered steps with clear milestones
- **Ask questions early** — Ambiguity in the spec is cheaper to resolve than ambiguity in the code
- **Check port/table/volume allocation** — Consult INFRASTRUCTURE.md to avoid conflicts

### Implementation Phase
- **Follow the spec** — The spec is the contract. Deviations require discussion
- **Follow the conventions** — API shape, logging format, test structure, naming patterns are all defined in CONVENTIONS.md
- **Keep it simple** — The user will push back on unnecessary complexity. Expect it
- **Write code that reads like prose** — Prioritize clarity over brevity
- **One concern per file** — Config in config, models in models, routes in routes
- **Write tests** — At minimum: import checks, contract tests, command/output tests (see CONVENTIONS.md → Testing)
- **Update the changelog** — Every implementation session gets a changelog entry
- **Log decisions** — Record non-obvious architectural choices in DECISIONS.md

### After Implementation
- **Verify against the spec** — Does the implementation match what was agreed?
- **Test the happy path and the failure path** — Upload a file, then upload a broken file
- **Run the test suite** — All tests pass before shipping
- **Update INFRASTRUCTURE.md** — New services, ports, tables, volumes
- **Document gotchas discovered during implementation** — If you hit a snag, write it down in the operations doc

---

## Project Lifecycle

```
  ┌─────────────────────────────────────────────────────┐
  │                                                     │
  │   1. SPEC          Define what we're building       │
  │   ─────────────────────────────────────────────     │
  │                         │                           │
  │                         ▼                           │
  │   2. ARCHITECTURE   Define how it fits together     │
  │   ─────────────────────────────────────────────     │
  │                         │                           │
  │                         ▼                           │
  │   3. PLAN           Define the order of work        │
  │   ─────────────────────────────────────────────     │
  │                         │                           │
  │                         ▼                           │
  │   4. IMPLEMENT      Write code, update changelog    │
  │   ─────────────────────────────────────────────     │
  │                         │                           │
  │                         ▼                           │
  │   5. VERIFY         Test, validate, document        │
  │   ─────────────────────────────────────────────     │
  │                         │                           │
  │                         ▼                           │
  │   6. SHIP           Merge, deploy, confirm          │
  │                                                     │
  └─────────────────────────────────────────────────────┘
```

Each phase produces artifacts. No phase is skipped.

---

## Summary

Build things that are simple, readable, private, and reliable. Start with a spec, draw the architecture, plan the work, write clean code, document the gotchas, and keep a changelog. Treat every project like someone else will maintain it — because future you is that someone.
