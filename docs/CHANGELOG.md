# Changelog

### 2026-06-29
- Add `scripts/auto-pull.sh` cron script: polls aspirant-* `:latest` images, recreates containers on SHA drift, delegates client swaps to `deploy-client.sh`, caches failed-deploy SHAs at `/var/lib/aspirant-auto-pull/known-bad.txt`, logs every decision as JSONL to `/var/log/aspirant-auto-pull/decisions.jsonl`. Eliminates manual `docker compose up -d <service>` after every aspirant-* merge.

### 2026-03-10
- Initial deploy repo created from aspirant-online monorepo split
- Production compose references new standalone image names (aspirant-{service})
- Dev compose builds from sibling repo directories
- Architecture documentation covering all service connections, data flows, and volumes
