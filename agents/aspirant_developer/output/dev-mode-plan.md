# Plan: `--dev` mode for aspirant-server

**Goal:** `go run main.go --dev` + `npm run dev` = full working stack, no setup.

---

## Current pain points

| Problem | Root cause |
|---------|-----------|
| Must pass 5+ env vars inline | No defaults, no .env in server repo |
| Must create local Postgres DB + user | Hard dependency on postgres dialect |
| Vite proxy port mismatch (8081 vs 8080) | Docker remaps 8080→8081; direct run stays on 8080 |
| pgvector extension error | Docker image has it, local Postgres doesn't |
| Missing dictionary file warning | Expects `/data/assets/games/dictionary.json` |
| No test user without manual bootstrap | Must POST /bootstrap/admin after first start |

---

## Proposed changes

### 1. aspirant-server: `--dev` flag

**Flag parsing in main.go:**

```go
devMode := flag.Bool("dev", false, "Run in development mode with SQLite and seed data")
flag.Parse()
```

When `--dev` is active, the server changes behavior in three areas:

#### 1a. SQLite instead of Postgres

Add `github.com/jinzhu/gorm/dialects/sqlite` to go.mod. In `SetupDBConnection()`:

- If `--dev`: open `./dev.db` (SQLite file in working directory)
- If not `--dev`: existing Postgres logic unchanged

The GORM v1 abstraction layer handles DDL and queries portably for everything the server uses — with two exceptions that need guarding:

| Postgres-specific code | Location | Dev-mode fix |
|----------------------|----------|-------------|
| `information_schema.columns` query | `database.go:71` | Skip entirely — fresh SQLite DB never has the legacy `access_role` column |
| `pg_stat_user_tables` query | `handlers/system.go:82` | Return empty/stub response in dev mode |
| `gorm:"type:jsonb"` on GameScore.Metadata | `data_models/game_score.go:15` | Change tag to `gorm:"type:text"` in dev mode, or use GORM's dialect-aware type mapping (see trade-offs) |
| `ALTER TABLE ... DROP COLUMN` | `database.go:93` | Skipped alongside the info_schema check |
| `UPDATE ... SET role_id = roles.id FROM roles` | `database.go:85` | Postgres-specific `FROM` join syntax — skip (fresh DB doesn't need it) |

**Implementation approach:** Add a `devMode bool` parameter to `SetupDBConnection()` and `AutoMigrate()`. Guard the legacy migration block with `if !devMode { ... }`. The legacy migration is a one-time cleanup from an old schema — it's irrelevant for a fresh dev database.

#### 1b. Auto-seed test data

After `AutoMigrate()` in dev mode, call a new `SeedDevData(db)` function that:

1. Creates roles (already happens in AutoMigrate)
2. Creates an admin user: `admin` / `admin` (bcrypt hashed)
3. Creates a regular user: `user` / `user`
4. Logs credentials to stdout: `[DEV] Admin user: admin/admin, Test user: user/user`

Guard with a check: only seed if users table is empty (same pattern as /bootstrap/admin).

#### 1c. Sensible defaults

In dev mode, automatically set:

| Variable | Dev default | Why |
|----------|-----------|-----|
| `GIN_MODE` | `debug` | Already the default, but make explicit |
| `JWT_SECRET` | `dev-secret` | Suppress the warning log |
| `ASSET_BASE_PATH` | `./dev-assets` | Local directory, auto-created |

No .env file needed. Server starts with zero configuration.

### 2. aspirant-client: port consistency

**Problem:** Vite proxy targets `localhost:8081` (Docker-mapped port), but `go run main.go` serves on `8080`.

**Fix:** Add a second proxy entry in `vite.config.js` that tries 8080 as a fallback, OR (simpler) document the convention:

**Recommended approach — env var in vite config:**

```js
proxy: {
  '/api': {
    target: `http://localhost:${process.env.API_PORT || '8081'}`,
    rewrite: (path) => path.replace(/^\/api/, ''),
  },
},
```

Then `npm run dev` uses Docker's 8081 by default. For direct server mode:

```bash
API_PORT=8080 npm run dev
```

Or add a package.json script:

```json
"scripts": {
  "dev": "vite",
  "dev:local": "API_PORT=8080 vite"
}
```

This avoids modifying vite.config.js back and forth and keeps the Docker workflow as default.

### 3. No other repos need changes

The `--dev` flag is entirely within aspirant-server. The vite config change is a minor quality-of-life improvement in aspirant-client.

---

## Risks and trade-offs

### SQLite vs Postgres compatibility

**Low risk.** The server uses GORM for all data access except two admin endpoints. Specific concerns:

| Concern | Assessment |
|---------|-----------|
| **GORM dialect differences** | GORM v1 handles SQLite DDL (CREATE TABLE, indexes, constraints). The easter hunt `uniqueIndex` tags work in both dialects. |
| **jsonb column (GameScore.Metadata)** | SQLite has no jsonb. Options: (a) use `type:text` — GORM stores JSON as text, queries still work for basic read/write; (b) use a build tag to swap the struct tag. Option (a) is simpler and sufficient for dev mode. |
| **Concurrent writes** | SQLite uses file-level locking. Fine for 1-2 dev users. Would cause "database is locked" under real load — this is dev-only, so acceptable. |
| **Auto-increment behavior** | SQLite uses ROWID, Postgres uses sequences. GORM abstracts both. No issue. |
| **Unique constraint errors** | Error messages differ between dialects. The easter hunt click handler checks for unique constraint violations — needs testing to ensure GORM returns a consistent error. If not, check error string for both "unique" and "UNIQUE". |

**Mitigation:** The dev database is disposable. If anything breaks, delete `dev.db` and restart. This is a feature, not a limitation — fresh state on demand.

### What dev mode is NOT

- Not a testing harness (use real Postgres for integration tests)
- Not a production-like environment (no Docker networking, no pgvector)
- Not a substitute for docker-compose.dev.yml (which tests the real stack)

Its only job: fast visual preview and API iteration.

### CGo dependency

SQLite via `github.com/mattn/go-sqlite3` (used by GORM v1's sqlite dialect) requires CGo. This means:
- macOS: works out of the box (Xcode command line tools)
- Linux: needs `gcc` installed
- CI: may need `CGO_ENABLED=1` explicitly

Alternative: use `modernc.org/sqlite` (pure Go) with a GORM adapter, but this would require more custom wiring with GORM v1. The CGo version is the pragmatic choice for a dev-only feature.

---

## Phasing

### Phase 1: Core `--dev` flag (do first)

1. Add `flag.Bool("dev", ...)` parsing in `main.go`
2. Add SQLite dialect dependency to `go.mod`
3. Branch `SetupDBConnection()`: SQLite file if dev, Postgres if not
4. Guard legacy migration in `AutoMigrate()` with `!devMode`
5. Add `SeedDevData(db)` function — admin + test user
6. Set sensible defaults (JWT_SECRET, ASSET_BASE_PATH)
7. Log dev-mode banner with credentials on startup

**Estimated scope:** ~80 lines of new code, ~20 lines of conditionals in existing code.

### Phase 2: Client convenience (do second)

1. Add `API_PORT` env var support to `vite.config.js`
2. Add `dev:local` script to `package.json`

**Estimated scope:** ~5 lines changed.

### Phase 3: Polish (can wait)

1. Stub the `GetDBStatsHandler` for SQLite (return empty table list)
2. Handle the `jsonb` column gracefully (text fallback)
3. Add `--dev-port` flag to override the listen port
4. Add `--dev-reset` flag to delete `dev.db` and start fresh
5. Document the workflow in CLAUDE.md

---

## End state

```bash
# Terminal 1 — server
cd ~/git/aspirant-server
go run main.go --dev
# → [DEV] SQLite database: ./dev.db
# → [DEV] Admin: admin/admin | User: user/user
# → [DEV] Listening on :8080
# → Database connected and migrated successfully

# Terminal 2 — client
cd ~/git/aspirant-client
npm run dev:local
# → Vite dev server running at http://localhost:5173
# → API proxy → http://localhost:8080

# Browser: http://localhost:5173 — full working app
```

Zero setup. Zero Docker. Zero env vars.
