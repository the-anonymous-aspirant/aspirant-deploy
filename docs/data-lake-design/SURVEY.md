# Aspirant Cell — Storage-Surface Survey (Phase 1 of #2149)

*Surveyed 2026-07-15 over SSH (`ssh -p 41922 aspirant@home.the-aspirant.com`). All sizes are raw command output from the cell; probe commands noted inline.*

## 1. Hardware ground truth

The task brief says "2 TB memory". Measured reality (`free -h`, `df -h`, `lsblk`, `vgs`):

| Resource | Actual | Notes |
|---|---|---|
| RAM | **15 GiB** (+4 GiB swap) | 3.7 GiB used, ~11 GiB available. This is the binding constraint for query engines, not storage. |
| `/data` | **1.8 TiB, 124 GiB used (8%)** | `md0` RAID1 mirror of 2× WDC **WD20EARS** (2 TB, 5400rpm WD Green). Array clean `[UU]`, 2/2 working, mdmonitor running. |
| `/scratch` | **916 GiB, empty** | Single WDC **WD10EADS** (1 TB WD Green), no redundancy. |
| `/` (SSD) | 100 GiB LV, 52 GiB used | Samsung 840 (233 GB). **~131 GiB unallocated in `ubuntu-vg-1`** — free SSD headroom. |
| Optical | ASUS BC-12D1ST Blu-ray | Curiosity; irrelevant. |

Drive-age caveat: WD20EARS/WD10EADS are ~2010-era consumer drives (assumption — verify by installing `smartmontools` and reading `Power_On_Hours`; `smartctl` is **not installed** on the cell today, so SMART health is currently unmonitored).

OS: Ubuntu 24.04.4 LTS, Docker 29.1.3. Uptime 114 days. Externally listening ports: 41922 (sshd), 80, 8081, 8999 (docker-proxy). fail2ban active.

## 2. Storage surfaces

### 2.1 Postgres (the only database)

One instance: `aspirant-online-postgres-1` (`pgvector/pg16`), volume `aspirant-online_pgdata` = **89.6 MB**; `aspirant_db` = **31 MB**. No other databases beyond templates.

Largest tables (`pg_total_relation_size`): `finance_transactions` 8.1 MB / 11,858 rows; `easter_hunt_egg_cells` 5.4 MB / ~34k rows; `advisor_chunks` (pgvector embeddings) 2.9 MB / 893 rows; `easter_hunt_clicks` 1.8 MB; `jobs` 1.5 MB / 420 rows; `browser_flow_outputs` 0.75 MB / 1,416 rows; then commander/goals/games/users tables all <100 kB.

Note: `pg_stat_user_tables.n_live_tup` for `finance_transactions` reads 463 vs. real count 11,858 → **autovacuum/analyze stats are stale** (worth a maintenance pass regardless of this project).

### 2.2 Filesystem `/data/aspirant` (bind-mounted into containers)

| Dir | Size | 30-day growth | What it is | Tier | Backed up? |
|---|---|---|---|---|---|
| `kiwix/` | **116 G** | 0 | One file: `wikipedia_en_all_maxi_2026-02.zim` | Re-downloadable cache | No (and doesn't need lake ingestion) |
| `ollama/` | 6.4 G | 0 | Model blobs (qwen2.5:3b, llama3.1:8b-q4) | Re-downloadable cache | No |
| `remarkable/` | 1.4 G | 0 | `xochitl/` reMarkable tablet notebook sync (~66 UUID doc dirs) | **Precious, irreplaceable** | No |
| `browser_flows/` | 132 M | **+1690 files / +128 MB** | Scrape outputs per flow UUID (66 dirs, 1,690 files); nightly 3am cron rewrites | Derived (re-scrapable in principle) | No |
| `files/` | 114 M | +47 files / +7.8 MB | `shared/Library/banned_books` 103 M (ebooks); `users/1/` 8.2 M: finance_reports, Värdeutlåtande (property valuations), walk screenshots | **Precious** (user files) | No |
| `assets/` | 42 M | +1 file | Website/games static assets (root-owned) | Rebuildable from repos | Partially (in git?) — verify |
| `audio/` | 19 M | 0 | Voice messages / audio | Precious | No |
| `advisor/` | 7.6 M | 0 | `uploads/` — advisor source docs | **Precious** (embeddings in PG derive from these) | No |
| `finance/` | 44 K | +5 files | `seed_data/categories.csv` (also in git) | In git | Yes (git) |
| `models/` | 4 K | 0 | Empty | — | — |

### 2.3 Docker

16 containers (aspirant-server, client blue/green pair, transcriber, advisor, commander, finance, remarkable, translator, browser, monitor, tor [unhealthy 13d], ollama, kiwix, postgres, docker-socket-proxy). Named volumes: only `pgdata` (89.6 MB) + two anonymous (~60 MB). **Images: 44.4 GB, of which 37.7 GB (84%) reclaimable** — the `*/5` auto-pull cron accretes `:latest` layers and nothing prunes them. This is the real driver of `/var/lib` = 44 G on the 100 G root LV.

### 2.4 In-memory stores

**None.** No Redis container, nothing on :6379.

### 2.5 External drive (on the workstation, not the cell)

The 250 GB USB drive currently has only its **empty** partition (`250GB`, 233 G, 1% used) mounted at `/run/media/aspirant/250GB`; the `250GB1` partition holding `ecosio/git/ecosio-bi-harness`, `pi-harness-setup-main`, and `ecosio-bi-workspace` (exFAT) is **not mounted right now** — size unverified this pass. Two lessons for the design: (a) ecosio work-product lives on a single unmirrored USB drive plugged into a workstation; (b) any backup target on this drive is only intermittently reachable.

### 2.6 Writers not captured above

- Host crons: `update-dns.sh` (*/5), `auto-pull.sh` (*/5, logs to `/var/log/aspirant-auto-pull`, 12 M), `cron_jobs_scrape.sh` (03:00 nightly → browser_flows + PG `browser_flow_outputs`).
- `/var/log` total 474 M; docker json-logs 19 M. Normal.
- systemd beyond docker: fail2ban, mdmonitor, fwupd — no data writers.

## 3. The headline numbers

- **Truly precious, irreplaceable data on the cell today: ≈ 1.7 GiB** (remarkable 1.4 G + files/users + audio + advisor uploads + banned_books if not re-acquirable ≈ +103 M) **plus 90 MB Postgres**.
- Re-downloadable caches: ≈ 122 GiB (kiwix + ollama).
- Derived/re-creatable: ≈ 175 MB (browser_flows, assets).
- Growth: ≈ 130–150 MB/month, essentially all browser_flows churn. At current cadence the precious set grows **< 2 GiB/year**.
- **Backup status today: zero.** No backup cron, no `/backup` dir, no off-cell copy. RAID1 protects against one disk death; it does not protect against `rm -rf`, filesystem corruption, ransomware, controller failure, fire, or the fact that both mirror members are equally elderly WD Greens.
