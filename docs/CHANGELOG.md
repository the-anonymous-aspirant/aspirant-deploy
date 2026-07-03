# Changelog

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
