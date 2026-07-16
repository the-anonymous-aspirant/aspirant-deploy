# Changelog

### 2026-07-16
- Harden `scripts/deploy-client.sh` (system_3 #2195-C1 friction): all compose invocations now target the two client services explicitly — an untargeted `docker compose up -d` pulls every project-wide missing image first, so a merged-but-not-yet-pulled sub-stack (or a dead registry link) blocked client swaps entirely; `swap` accepts an optional explicit slot (`swap green`) that is idempotent and retry-safe, where the bare toggle form flips direction on every rerun; pure helpers extracted behind an `ASPIRANT_DEPLOY_CLIENT_LIB=1` escape hatch with unit coverage in `tests/deploy_client_unit.sh` (mirrors the `auto_pull_unit.sh` pattern).
- Add the Penpot design service sub-stack (system_3 #2195): upstream Penpot 2.16.2 (frontend/backend/exporter) mirrored to `ghcr.io/the-anonymous-aspirant/penpot-*` and digest-pinned (the cell cannot pull docker.io over its Wi-Fi uplink — see DECISIONS.md), dedicated postgres:15 + redis:7 on an isolated `penpot` network, storage bind-mounted under `/data/aspirant/penpot/`. Secrets (`PENPOT_SECRET_KEY`, `PENPOT_DB_PASSWORD`) migrate from the dev-box `.env` and are gated at compose boot. Public ingress (`design.the-aspirant.com` vhost) and the `/admin/penpot` entry land with aspirant-client (system_3 #2195-C1); content migration is #2195-B1. See docs/PENPOT_SPEC.md + docs/PENPOT_ARCHITECTURE.md.

### 2026-07-09
- Guard `JWT_SECRET` at compose boot: `${JWT_SECRET:?...}` on the `server` service refuses to render `docker compose up` when the variable is unset, replacing the silent-fallback path that let an insecure default reach production. `.env.example` no longer ships the `change-me` placeholder — the entry is empty with a generation-hint comment mirroring the existing `DB_PASSWORD` block. Coordinates with aspirant-server PR #56 + aspirant-online PR #53 (system_3 #1374). Live rotation on cell (`openssl rand -base64 32` into `~/aspirant-deploy/.env` + `docker compose up -d --force-recreate server`) invalidates existing tokens by design — operator action tracked on the system_3 task.

### 2026-07-03
- Remove aspirant-browser `0.0.0.0:8089` host publish in production compose so the service is only reachable through the authed `client(nginx) → server:8080 → browser:8000` path (system_3 #1375). Dev compose keeps the mapping but binds it to `127.0.0.1` so pytest and curl from the developer host still work while the port stops leaking on the LAN. `docs/ARCHITECTURE.md` §Network updated to note the internal-only binding.
- Set `BROWSER_ENV=production` on the browser service so the FastAPI hardening lands in prod: `/docs`, `/redoc`, `/openapi.json` return 404 and the `Server` response header is rewritten from `uvicorn` to `aspirant` (system_3 #1444). Dev compose intentionally omits the override.

### 2026-06-29
- Add `scripts/auto-pull.sh` cron script: polls aspirant-* `:latest` images, recreates containers on SHA drift, delegates client swaps to `deploy-client.sh`, caches failed-deploy SHAs at `/var/lib/aspirant-auto-pull/known-bad.txt`, logs every decision as JSONL to `/var/log/aspirant-auto-pull/decisions.jsonl`. Eliminates manual `docker compose up -d <service>` after every aspirant-* merge.

### 2026-03-10
- Initial deploy repo created from aspirant-online monorepo split
- Production compose references new standalone image names (aspirant-{service})
- Dev compose builds from sibling repo directories
- Architecture documentation covering all service connections, data flows, and volumes
