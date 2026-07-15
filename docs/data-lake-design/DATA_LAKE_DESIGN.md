# Aspirant Data Lake — Design Spec

*Task #2149 · 2026-07-15 · Status: design for operator review, no implementation yet.*
*Rev 2 (2026-07-15): folds the operator's answers to the three blocking questions — personal-data scope confirmed (§0.3, §2, §5g), Garage-vs-build-own compared (§3.5), RPO 24 h confirmed (§6), encryption + access rewritten as mandatory (§9), compliance section added (§14).*
*Companion: [SURVEY.md](./SURVEY.md) — full Phase-1 storage-surface inventory with raw evidence.*

## 0. The three corrections that shape everything

1. **The cell has 15 GiB of RAM, not 2 TB.** The 2 TB is storage: a 1.8 TiB RAID1 pair (`/data`, 8% used), a 916 GiB empty scratch disk, and a 233 GiB SSD with ~131 GiB unallocated. 15 GiB RAM rules out Spark/Trino/Hive-class engines and makes DuckDB-class embedded engines the only sane choice. This is a feature: at your scale, the heavyweight stack is pure liability.

2. **Your precious cell-side data is ~2 GiB, growing < 2 GiB/year — and it has zero backups.** (The 2026-07-15 scope extension adds system_3's workstation-side data — a 5.8 GB Postgres, 1.2 GB of session transcripts, cron logs — as lake sources too; see §5b. The ordering conclusion is unchanged.) Of 124 GiB on `/data`, 122 GiB is re-downloadable cache (a Wikipedia ZIM + Ollama models). The irreplaceable set — reMarkable notebooks (1.4 G), user files/valuations/finance reports, advisor uploads, audio, and a 31 MB Postgres — is protected today only by RAID1 across two ~2010-era WD Green drives of the same model and age (correlated-failure risk), with no protection at all against deletion, corruption, ransomware, or fire. **The most valuable 20% of this project is the backup subsystem, and it should ship first.** A data lake is not a backup, and a backup is not a data lake; this design delivers both, in that order.

3. **"ALL my data" is confirmed to include personal-life data** (operator, 2026-07-15): personal photos, personal email, SMS/Telegram archives, doctors' records, finance data, "and more". Revised ingest estimate: **50–500 GiB up front, growing 10–50 GiB/yr** (photos dominate). The 1.8 TiB RAID1 still fits this comfortably; what changes materially is everything downstream of sizing — backup-target economics (§6), encryption moves from optional to mandatory (§9), and compliance exposure becomes real (§14). None of these sources live on the cell today; getting them *out* of phones and providers is an export problem before it is a connector problem (§5g).

## 1. Architecture overview

```
producers (unchanged)                    lake on the cell (new, additive)
─────────────────────                   ────────────────────────────────
CELL                                    ┌─ S3 object store (Garage, /data)
 aspirant pg ──CDC/pg_dump──┐           │   bronze/  raw, immutable
 /data/aspirant/* ──rclone──┤           │   silver/  parquet (DuckLake tables)
 browser_flows cron ────────┤           │   gold/    curated marts (dbt-built)
WORKSTATION                 ├─ingest──▶ ├─ DuckLake catalog (existing Postgres)
 system3 pg ──CDC/cursor────┤  (Dagster │─ dbt: bronze→silver→gold models
 pane transcripts ──rclone──┤   daily + │─ backup: restic → /scratch + off-cell
 cron logs ──rclone─────────┤   stream) │─ aspirant-explorer frontend (read-only)
 ecosio drive (manual) ─────┤           └─ BI: Metabase over gold
PERSONAL (exports, §5g)     │
 photos/email/msgs/records ─┘
```

Cardinal rule: **the lake is an analytical copy, never the system of record.** Apps keep owning their native stores; every connector is read-only against its source; killing the lake harms nothing upstream. That is also the rollback plan.

## 2. Medallion mapping for THIS data

Medallion is retained, with one justified refinement: it was defined for tabular pipelines ([Databricks' canonical description](https://www.databricks.com/glossary/medallion-architecture)), and most of your bytes are binary media. So: **tabular data moves through bronze→silver→gold as tables; binary blobs live once in bronze, content-addressed, and their *derived artifacts* (text, thumbnails, metadata rows) are what appear in silver.** Copying a PDF three times to "promote" it would be cargo cult.

| Layer | Contract | This operator's contents |
|---|---|---|
| **Bronze** | Immutable, append-only, exactly-as-received, partitioned by ingest date. Never edited, only superseded. | Nightly `pg_dump -Fc` snapshots; raw reMarkable `xochitl/` blobs; raw uploads/audio/ebooks; raw browser-flow scrape outputs; ecosio drive image. Blob layout: `bronze/blobs/sha256/ab/cd/<hash>` + source-path manifest — dedup for free, corruption detectable forever. |
| **Silver** | Cleaned, typed, deduplicated, queryable. All tabular, all DuckLake-managed parquet. | Per-table typed exports of `aspirant_db` (finance_transactions, jobs, goals, commander, browser_flow_*); parsed scrape outputs; **asset inventory** (one row per blob: hash, source, mtime, mime, size, provenance); extracted text of every PDF/ebook/notebook; image EXIF + thumbnails; audio transcripts (transcriber service already exists). |
| **Gold** | Small, curated, opinionated marts serving a human or a page. | Finance monthly/YoY marts (replaces ad-hoc SSH+psql report pulls); cross-app timeline ("everything about entity/date X"); freshness+health rollups that the frontend and monitor read. |

"Cleaning" is type-specific: for Postgres state it means typed columns, dedup, soft-delete handling; for scrapes it means parse-don't-store-HTML; for PDFs/notebooks it means extraction (text, OCR), not mutation; for images it means metadata + derivatives. Bronze immutability is what makes a parquet file corrupted-and-noticed-in-6-months a non-event: re-derive silver from bronze.

Scope extension (2026-07-15): the personal-data classes land the same way. Photos are bronze blobs whose silver is EXIF rows + thumbnails (face/scene tagging only as a consent-gated later option); email/SMS/Telegram exports are bronze blobs (mbox / JSON / XML) whose silver is one typed `messages` table unified across channels (channel, sender, recipients, ts, body, attachments → blob refs); medical and finance documents are bronze blobs + extracted text in silver, tagged `sensitivity=high` in the asset inventory so §9's stricter handling keys off a column, not a folder convention.

Excluded from the lake by policy: `kiwix/` ZIM and `ollama/` models (re-downloadable; store a checksum + re-download manifest in silver instead — 122 GiB saved), Docker images, git-tracked assets.

## 3. Object store choice

The premise "MinIO or another..." needs updating: **MinIO Community Edition is effectively dead.** Admin features were stripped from the community console in 2025 ([Blocks & Files](https://www.blocksandfiles.com/ai-ml/2025/06/19/minio-users-complain-after-admin-ui-removed-from-community-edition/1610856)), distribution became source-only with no binaries/images, and the GitHub repo is now archived read-only ([github.com/minio/minio](https://github.com/minio/minio), archived April 2026) with users pointed at the commercial AIStor. Building an unmaintained AGPL fork into your foundation in July 2026 would be adopting an orphan.

| Candidate | License | Fit for 15 GiB-RAM single host | Verdict |
|---|---|---|---|
| **Garage** | AGPL-3.0 | Single static binary, tiny footprint, built for small self-hosted deployments; S3 API covers rclone/DuckDB/dlt. No S3 Object Lock; versioning support to verify (assumption — verify against [garagehq.deuxfleurs.fr](https://garagehq.deuxfleurs.fr/) feature matrix before implementation). AGPL is irrelevant here — nothing is distributed. | **Recommended** |
| **SeaweedFS** | Apache-2.0 | Mature (2015), closest drop-in MinIO replacement, S3 versioning + TTL; more moving parts (master/volume/filer/S3 gateway) than a single binary. | **Runner-up** — switch to it if object versioning or growth beyond one host becomes real |
| MinIO CE | AGPL-3.0 | Archived upstream, source-only, no maintenance. | Disqualified |
| RustFS | Apache-2.0 | New (2025) MinIO-alike; too young to bet the foundation on. | Watch list |
| Ceph RGW | LGPL | Designed for clusters; ops burden and RAM appetite absurd at this scale. | Disqualified |

(Comparison context: [lowcloud](https://lowcloud.io/en/blog/minio-alternatives), [pistack](https://www.pistack.xyz/posts/2026-05-03-self-hosted-s3-object-storage-minio-seaweedfs-garage-guide/).)

Null alternative considered: plain directories, no S3. Rejected because the S3 API is what buys tool compatibility (rclone, restic, DuckDB `httpfs`, dlt, presigned URLs for the frontend) and clean producer/consumer decoupling — but note the escape hatch below (§9, lock-in).

## 3.5 Path A (adopt Garage) vs Path B (build our own S3-parity server)

Operator (2026-07-15): Garage is fine, *or* "if we can develop a standalone free s3-parity equivalent to garage, I would not mind that." That reads as a green-light to *design* Path B, not an obligation to build it. The comparison, honestly:

| | Path A — Garage as-is | Path B — own S3-parity server |
|---|---|---|
| Time to a working lake | Days (single binary + config) | 3–6 engineer-weeks (~5–8k SLOC) before lake work resumes |
| API surface | Full-enough S3 today; exercised against rclone/restic/DuckDB/boto3 by a whole community | We implement + test PUT/GET/HEAD/DELETE, multipart, ListObjectsV2, presigned URLs, checksums — then re-verify against every client library we adopt |
| Correctness risk | Garage's problem; shipping since 2020 | Ours alone; S3 semantics are subtly weird (multipart ETags, chunked signing, presign validation, header canonicalization) and every consumer assumes bug-for-bug real-S3 behavior |
| Maintenance | Quarterly pinned-version bump | ~5% engineering time forever: security patches, S3 API drift, edge cases |
| Exit story | Near-zero lock-in: AGPL source; data is plain parquet + blobs any S3 client can read; if Garage dies like MinIO, `rclone sync` to a successor, formats unchanged | No vendor risk by construction — but we inherit all vendor duties alone |
| Fleet fit | One more pinned container | A new service with its own Spec/Architecture/Plan/tests per DEVELOPMENT_PHILOSOPHY — instantly among the largest services in the fleet |

**Recommendation: Path A, unambiguously — for phase 1 and for the foreseeable default.** The MinIO lesson (§3) argues for *format* exits, not for owning the server: what protects this fleet is that bronze/silver are parquet + content-addressed blobs behind a commodity API, so any S3-parity store — Garage, SeaweedFS, or a future home-grown one — can serve the same bytes. Spending 3–6 weeks re-implementing a commodity would push the actual burning need (§6 backups) out by exactly that long, and buy protection against a risk (Garage abandonment) whose mitigation is already cheap (`rclone sync` to a successor).

Path B stays a **designed contingency with explicit triggers**: Garage archival/abandonment, an unfixable data-integrity bug, or a hard feature wall (e.g. Object Lock becoming compliance-mandatory). If a trigger fires, Path B's scope is exactly the table above's row 2 — and per R2/S2 it would be its own epic. Deliberately **not** filed as a child task now: filing an implementation task for a path the design recommends against would manufacture backlog.

## 4. Deployment shape

**Co-resident dockerized service on the cell** — there is no second host, and the data's gravity is here. Specifics:

- New `lake` service group in `aspirant-deploy` compose (per DEVELOPMENT_PHILOSOPHY "when to create a new service": distinct lifecycle, distinct storage, clear API boundary — it qualifies).
- Garage data on `/data/lake/` (RAID1). Garage metadata DB on the SSD: carve a ~20 G LV from the 131 G free in `ubuntu-vg-1` (metadata is hot random I/O; the WD Greens are terrible at that).
- **Pin image versions.** The `*/5` auto-pull cron re-pulls `:latest` and has clobbered locally-built images before; the lake must not be surprise-upgraded by a cron. Also add a monthly `docker image prune` — 37.7 GB (84%) of image storage is currently reclaimable garbage crowding the root LV.
- Loopback/docker-network only; **no new public ports** (80/8081/8999 are already internet-exposed; the lake must not join them).

## 5. Ingestion connectors, per surface

One scheduled **ingest-runner** container (Python + rclone + DuckDB), one run ledger table, per-source jobs:

| Source | Path | Effort |
|---|---|---|
| Postgres | Nightly `pg_dump -Fc` → bronze; per-table parquet via DuckDB `postgres_scanner` → silver. Logical replication/CDC is unjustifiable at 31 MB & this change rate — batch dailies are ~free and restore-testable. | **Trivial** |
| `files/`, `advisor/uploads`, `audio/` | Nightly `rclone sync` → bronze blobs + inventory rows; extraction (pdftotext, transcriber) → silver. | **Trivial** (sync) + **Medium** (extraction) |
| `browser_flows/` | The 3 a.m. scrape cron already rewrites ~1,690 files/month (the cell's only active writer). Add a post-scrape step: copy raw into dated bronze, parse to silver parquet. Also fixes the current "history overwritten nightly" data loss. | **Small** |
| reMarkable `xochitl/` | Nightly sync → bronze; derived rendering (.rm→PDF/SVG) + OCR → silver. Renderer choice is real work. ⚠️ Survey shows **0 new files in 30 days — the tablet sync itself may be broken; verify before building anything on it.** | **Real work** |
| `assets/`, `finance/seed_data` | Git-tracked/rebuildable: inventory checksums only. | Trivial |
| kiwix, ollama | Excluded; manifest row only. | Trivial |
| ecosio 250GB1 drive | Manual `rclone sync` when mounted at the workstation (it currently isn't — only the empty partition is). Treat as an external site with a "last seen" freshness alert. | Small, but **availability-gated** |
| Host/app logs | Out of scope v1; keep logrotate. | — |

## 5b. System_3 integration (scope extension, operator 2026-07-15)

system_3 — running on the workstation, not the cell — becomes a first-class source. Measured this pass:

| Source | Size / shape | Ingestion path |
|---|---|---|
| `system3` Postgres | **5.8 GB** (dwarfs everything aspirant-side); dominated by `activity_log` monthly partitions (Jun 2.9 G, May archive 2.6 G, Jul 125 M post-churn-fix), `request_log` 58 M, `comments` 23 M, `tasks` 3 M | Split by table nature: `activity_log`/`request_log` are **append-only** → cursor-based incremental batch (see §5c — CDC on an append-only event log buys nothing). Mutable tables (`tasks`, `comments`, `mentions`, `item_prs`) → CDC stream. Matviews (`v_system_anomalies`) → recompute in gold, don't replicate. |
| Pane transcripts | 1.2 GB JSONL under `~/.claude/projects/` | Nightly `rclone sync` → bronze blobs; silver = parsed per-turn rows (session, actor, ts, role, token counts). **Privacy flag**: transcripts contain secrets pasted mid-session — see §12 legal questions. |
| Cron logs | ~130 MB rotating `.<cron>.log.YYYYMMDD` at repo root | Nightly rclone of rotated-out files → bronze; silver = parsed run ledger. Trivial. |
| Frontend `request_log` | 58 MB, append-only table | Cursor-based incremental, same as activity_log. |

Cross-host consequence: workstation → cell ingest runs over the existing SSH path (rclone-over-ssh or an S3 key scoped write-only-bronze reachable via tunnel). If the cell is down, CDC slots on the workstation **retain WAL until the consumer returns** — see the slot-risk warning in §5c. The test/dogfood/scratch databases (system3_test, dogfood copies, ~2.4 GB) are explicitly excluded.

## 5c. CDC design

Operator intent: every DB write persisted to the lake continuously, not just periodic snapshots. Ground truth first: **both Postgres instances currently run `wal_level=replica`** (verified via `SHOW wal_level` on each) — logical CDC requires `wal_level=logical` + a restart of each instance before anything streams. That is a scheduled-downtime prerequisite, and on system_3's side it must respect the backend-restart discipline.

**Where CDC actually pays.** CDC's value is capturing *mutations* (UPDATE/DELETE) you'd otherwise lose between snapshots. Two-thirds of the interesting volume here (`activity_log`, `request_log`, browser-flow outputs) is append-only; for those, an incremental cursor read (`WHERE id > :last`) delivers the same completeness with zero replication-slot risk. So the design is **hybrid**: CDC for mutable business tables, cursor batch for append-only logs, dumps for disaster recovery regardless.

| Candidate | Shape | Pro / con for this fleet |
|---|---|---|
| Debezium + Kafka Connect | The canonical stack; Connect has a production S3 sink | JVM ×3 (broker, Connect, schema registry realistically) on a 15 GiB host serving two small PGs — ops burden and RAM wildly out of proportion. **No.** |
| [Debezium Server](https://debezium.io/documentation/reference/stable/operations/debezium-server.html) | Single container, no Kafka; sinks are brokers (Redis Stream, NATS, Pulsar…) — **no S3 sink**, so it still needs a broker + a consumer writing parquet | Two extra moving parts per host. Credible, but heavier than the job. Fallback if the lightweight option disappoints. |
| **Lightweight logical-replication consumer** (dlt's `pg_replication` source, or ~200 lines of Python on `pgoutput`) | One process per source PG: reads the slot, micro-batches events to bronze parquet every N minutes | Right-sized: no broker, no JVM, state = slot LSN + file cursor; runs as a Dagster schedule/sensor. **Recommended.** (assumption — verify dlt `pg_replication` maturity in a spike before committing; hand-rolled `pgoutput` consumer is the fallback) |
| Snapshot-diff polling | Periodic full/keyed re-reads, diff at silver | No PG config change needed, but O(table) reads and misses intermediate states; only right for tiny mutable tables. Kept as the degraded mode if `wal_level` change is refused. |

**Pipeline shape**: slot (`pgoutput`, one publication per source DB covering mutable tables) → consumer micro-batches raw change events to `bronze/cdc/<db>/<table>/date=…/*.parquet` (event = op, LSN, ts, before/after JSON) → dbt models in silver **merge** events into current-state tables (dedup on primary key + LSN ordering handles replays and late arrivals; DuckLake snapshots make each merge atomic and time-travelable). Replay = truncate silver table, re-run merge over bronze history — bronze is never mutated.

**Schema evolution**: `pgoutput` emits relation metadata with each change; new columns appear in events automatically. Consumer policy: write events with the *union* schema (parquet handles added columns natively); dbt staging models select explicit columns, so a new column is invisible until a model is updated to expose it — absorbed without replay. Column *renames/drops* are breaking and get a documented runbook (rare on both fleets).

**The risk nobody mentions**: an unconsumed replication slot pins WAL forever — consumer dies silently for a month ⇒ source disk fills ⇒ **the production DB goes down**. This is the single worst failure mode CDC imports into the fleet. Mitigations: `max_slot_wal_keep_size` cap on both PGs (bounded damage: slot invalidates rather than disk fills, lake re-syncs from snapshot), slot-lag gauge in §10 observability with a red alert, and the nightly dump lane as the always-on recovery floor.

## 5d. dbt as the modeling layer

**Recommended: dbt-core + [dbt-duckdb](https://github.com/duckdb/dbt-duckdb)** running against the DuckLake catalog (DuckLake connections supported as of dbt-duckdb 1.9.6 — verify the exact profile shape for self-hosted [not MotherDuck] DuckLake in a spike; the adapter docs demonstrate `is_ducklake` profiles). All silver→gold transforms (and the CDC merge models) become dbt models; bronze stays outside dbt (immutable ingest is not a transform).

- **vs SQLMesh**: genuinely better incremental-model semantics and environment management, and it can even read dbt projects ([comparison](https://www.modern-datatools.com/compare/dbt-vs-sqlmesh)); but smaller ecosystem, and its killer features (virtual environments, column-level lineage across warehouses) matter at team scale, not single-operator scale. Revisit if incremental-model pain appears.
- **vs plain SQL scripts**: dbt buys dependency-ordered DAG execution, `dbt test` (not-null/unique/relationship checks on every run — your data-quality lane), docs + model-level lineage UI for free, and models-as-files that agents can PR against with review. That last point is the real win for this fleet: **the transform layer becomes corpus-like — versioned, reviewable, agent-editable.**
- What dbt does *not* give: blob/asset lineage (the §7 inventory table owns that), ingestion orchestration (Dagster's job), and column-level lineage (accept the gap; model-level suffices at this scale).

## 5e. Daily orchestrator

| Candidate | Single-host fit | dbt integration | Verdict |
|---|---|---|---|
| **Dagster OSS** | Compose-friendly ([official guide](https://docs.dagster.io/deployment/oss/deployment-options/docker)): webserver + daemon + code container; run-storage can reuse the existing Postgres | [dagster-dbt](https://docs.dagster.io/integrations/libraries/dbt) maps every dbt model to an asset — the UI shows the whole bronze→gold graph with per-asset freshness and retries | **Recommended** |
| Airflow | Scheduler + webserver + metadata DB; the heaviest idle footprint of the group and task-centric, not asset-centric | Cosmos plugin, adequate | Over-toolerd for one host |
| Prefect | Light server, nice API | prefect-dbt exists but is shallower than dagster-dbt | Second place |
| Argo Workflows | Requires Kubernetes | — | Disqualified (no k8s, and installing one for this would be malpractice) |
| Plain cron | Zero new services; already the cell's idiom | None — you hand-order the DAG, hand-build retries/alerting | The honest null option; what §11 phase 1-2 uses before the orchestrator lands |

Why an orchestrator at all, given cron got this far: the moment CDC merge → dbt build → mart publish → backup verify have *ordering dependencies and retry semantics*, cron chains become the silent-failure machine the fleet already knows (unwired safety nets, invisible cron drift). Dagster's asset graph + per-asset freshness policies is exactly the missing §10 observability surface, and its daily schedule replaces four would-be crons. RAM cost is a few hundred MB across services (assumption — verify by measuring the compose stack during the spike; no official figure published). State/backup story: Dagster's run history lives in the existing Postgres ⇒ already inside the §6 backup scope.

Deployment: one `orchestration` compose group on the cell (pinned versions, per §4); workstation-side collectors stay dumb (cron/systemd timer pushing to bronze), the cell-side Dagster owns everything downstream.

## 5f. Insights & visualization

Gold marts are **published to Postgres** (tiny tables, e.g. `gold` schema in the existing cell instance) as the final dbt step. This decouples BI-tool choice from DuckDB-driver maturity — every tool on earth speaks Postgres.

| Candidate | Fit | Verdict |
|---|---|---|
| **Metabase** | Single JVM container, ~1-2 GB RAM ([docs](https://www.metabase.com/learn/metabase-basics/administration/administration-and-operation/metabase-in-production)); question-builder the operator can use without SQL; points at the gold schema | **Recommended for exploration** |
| Superset | 2-4 GB+, multiple services, richer chart types | Heavier than the need |
| Grafana | Lightest idle (~200-300 MB); superb for the §10 *ops* metrics, clumsy for ad-hoc analytical questions | Adopt *for observability dashboards* if aspirant-monitor outgrows itself, not for BI |
| Custom Vue page (aspirant DS) | Full design-system consistency; every chart is a build | Reserve for the top ~6 curated insights on aspirant-explorer's Overview once questions stabilize in Metabase |

Pattern: **explore in Metabase → promote stabilized questions to dbt gold models → hand-build the few that earn a place in aspirant-explorer.** BI tools are where questions are discovered; the design system is where answers are productized.

## 5g. Personal-data sources (scope confirmed 2026-07-15)

None of these live on the cell or the workstation today; each is an **export problem before it is a connector problem** — the hard part is getting a complete, repeatable feed out of a phone or a provider, and every one is availability-gated on an operator action (like the ecosio drive):

| Source | Likely export path | Bronze form | Silver form | Effort |
|---|---|---|---|---|
| Photos | Google Takeout / iCloud export / periodic phone rsync (Syncthing-class) | Original files, content-addressed | EXIF rows, thumbnails, hash-dedup | Connector trivial; **the recurring export routine is the work** |
| Personal email | Recurring IMAP pull (mbsync/imapsync) or provider takeout | mbox / .eml blobs | Unified `messages` table | Medium — recurring IMAP beats one-off takeout |
| Telegram | Desktop-client JSON export (assumption — verify completeness vs API export before relying on it) | JSON export dirs | Same `messages` table | Small parse; export is manual |
| SMS | Android XML backup (SMS Backup & Restore-class app) | XML blobs | Same `messages` table | Small |
| Medical + finance records | Scans + portal PDF downloads | Blobs, `sensitivity=high` | Extracted text; typed rows where structured | Trivial ingest; sourcing stays manual forever |

Design consequence: these connectors are **inbox-shaped** — a watched `incoming/` prefix in bronze that the operator (or a phone-side job) drops exports into, with per-source freshness alerts ("no photo export in 90 d") instead of scheduled pulls the cell cannot perform itself. Sizing: photos dominate (10s–100s GiB), messages 10s of GiB, records negligible — the §0.3 revision.

## 6. Backup strategy (ships before the lake proper)

3-2-1. The cell-native precious set is tiny (~3 GiB incl. dumps); the confirmed personal-data scope (§0.3) raises the eventual footprint to **50–500 GiB**, which changes target economics but not the architecture — restic dedup + an off-site S3 target stays right:

- **Tier 1 — nightly, on-cell, cross-disk**: `restic` repo on `/scratch` (916 G idle, physically separate disk). Scope: bronze bucket + pg dumps + DuckLake catalog dump + `/data/aspirant` precious dirs (belt-and-suspenders during migration). Restic gives encryption, dedup, and content checksums ([restic docs](https://restic.readthedocs.io/)). `/scratch` is a lone elderly disk — it is a second copy, not an archive.
- **Tier 2 — nightly, off-cell**: same restic repo replicated to an off-site S3 target (Backblaze B2 ≈ $6/TB-month — assumption, verify current pricing; at the revised 50–500 GiB scope ⇒ roughly $0.30–3/month, still trivially cheap but no longer "pennies", and a full-restore egress at 500 GiB becomes a modest line item to price before drill #1) **or** pull-based to the workstation's external drive. Recommend B2: the external drive is intermittently mounted and lives in the same building (fire domain).
- **Integrity**: `restic check` weekly; `restic check --read-data` monthly (this is what catches silent bit-rot on old drives); alert if last-success age > 26 h.
- **Restore drill**: quarterly, scripted: restore to `/scratch/restore-test`, `pg_restore` into a scratch DB, run 5 smoke queries, diff inventory counts. **An untested backup is a hypothesis, not a backup.** The drill is a cron with a red alert on failure, not a calendar intention.
- **Rollback plan** (lake itself): connectors are read-only; to abandon, stop the lake compose group and delete `/data/lake` — no producer notices. Keep the pre-lake `rsync` snapshot of `/data/aspirant` on `/scratch` for the first 90 days.

RPO today is ∞. **Confirmed (operator, 2026-07-15): RPO 24 h is acceptable.** Nightly cadence is final; RTO half-a-day stands as the working target; last-24h CDC-window losses recover by replay from the source systems.

## 7. Metadata & catalog

**DuckLake v1.0** (production-ready April 2026, in DuckDB ≥ 1.5.2 — [ducklake.select](https://ducklake.select/2026/04/13/ducklake-10/)): catalog = SQL tables in your **existing Postgres** (new `lake_catalog` database, same instance), data = parquet in the object store, engine = DuckDB anywhere (ingest-runner, frontend API, your laptop over an SSH tunnel — "multiplayer DuckDB").

Why not the requested trio: Iceberg/Delta/Hudi all assume a separate catalog service and JVM/Spark-ecosystem tooling; on one 15 GiB host they add operational surface and deliver nothing at gigabyte scale. Iceberg is the credible fallback if you ever outgrow this (parquet migrates; see §9). DuckLake also gives snapshots/time-travel, which substitutes for most object-versioning needs.

The catalog now lives in Postgres ⇒ **the Postgres backup protects the lake's brain**; it's already in §6 scope. The blob **asset inventory** (silver table) is the catalog for non-tabular data: every blob row carries sha256, source, provenance, ingest run id.

## 8. Frontend — `aspirant-explorer`

New Vue 3 microservice using the aspirant design system, backed by a small FastAPI read-only API (DuckDB against the catalog + presigned Garage URLs). Not MinIO's (now-gutted) object browser — a curated surface:

1. **Overview** — lake size by layer, per-source freshness (green/amber/red vs SLA), backup last-success + last-verify + last-drill ages, RAID/disk status. *The page answers: "is my data safe, and is it fresh?"*
2. **Datasets** — DuckLake tables: schema, row counts, snapshot history (time-travel picker), 100-row preview, SQL box (read-only key).
3. **Documents & media** — faceted browse of the asset inventory (type/source/date), PDF/notebook viewer with extracted text, image gallery via thumbnails, audio player with transcript.
4. **Search** — FTS over extracted text + optional vector search reusing the advisor's embedding machinery.
5. **Provenance** — for any object: source path, ingest run, bronze blob hash, derived-artifact links; for any table: which runs/snapshots built it.
6. **Runs & health** — connector ledger with per-run bytes/files/duration/status.

Auth: reuse aspirant-server's session/user model (operator decision, §12); served on the internal network only, never on the public :80. Sensitive-class objects (§9 layer 2) render through the API's in-memory decryption path — no presigned URLs for those — and every sensitive-class read is access-logged (§14).

## 9. Access control, encryption, secrets, lock-in

*(Rewritten 2026-07-15: with medical, financial, and message data confirmed in scope (§0.3), encryption and tightened access move from nice-to-have to mandatory.)*

- **Encryption at rest is non-optional, in three layers:**
  - **Layer 1 — LUKS on `/data`, `/scratch`, and the lake's SSD LV.** Previously an operator-optional question; now the floor. The cost stays real: unattended reboot needs a keying story — on-site USB key, manual unlock over SSH, or network-bound decryption (clevis/tang-class) (pick in §12 Q-N3; assumption — verify clevis/tang fit on the cell's Ubuntu before committing). Garage does not encrypt objects at rest by itself; its own guidance is disk-level or client-side encryption (assumption — verify against the Garage security docs during the phase-2 spike).
  - **Layer 2 — envelope encryption for `sensitivity=high` objects** (medical, finance, message archives, any photo sets the operator flags): the ingest-runner generates a per-object DEK (AES-256-GCM), encrypts the blob client-side before PUT, and wraps the DEK with a KEK that lives **off-cell** (operator's password manager or a hardware token — never on the cell's disks). Wrapped DEKs ride in the asset-inventory row. Honest trade-off: envelope-encrypted objects are opaque to DuckDB-over-S3 and to presigned URLs — they are served only through the explorer API, which unwraps in memory. That is exactly why layer 2 is scoped to sensitive classes rather than the whole lake: encrypt everything client-side and you lose the query-parquet-in-place property the design is built on.
  - **Layer 3 — backups**: restic is always encrypted (§6); the restic password joins the KEK in off-cell custody. **Crypto-erasure**: destroying a wrapped DEK renders its immutable bronze blob permanently unreadable — this is the §14 erasure mechanism that squares "bronze is never edited" with "some data must be deletable".
- **Key rotation**: KEK annually + on-compromise (re-wrap DEKs; no blob rewrite); Garage access keys semiannually via a documented 5-minute runbook; restic password never rotates silently (rotation = new repo + verified re-seed).
- **Access model, tightened**: every client authenticates — including the operator's own workstation tooling; IP-origin is not an auth boundary (the fleet's standing weakness). Default posture is read-only: per-connector Garage keys write-only to their bronze prefixes; explorer API and BI hold read-only keys; the only silver/gold writer is the ingest/dbt runner. Anything else that writes requires an explicitly elevated session — the admin key stays offline, is checked out for the task, and is revoked after.
- **Secrets**: compose env-files as today; the existing pattern (DB password readable in container env) remains the fleet's real weak point — a hardening task independent of the lake, but the KEK never enters that pattern.
- **In transit**: on-host docker networks; workstation→cell ingest over SSH; remote human access via SSH tunnel only; no new public ports (§4 stands).
- **Threat model note**: centralization now concentrates *legally sensitive* blast radius, not just operational (§14). The internet-exposed :80/:8081/:8999 services live one privilege escalation away from the lake volumes — and LUKS does not protect a *running* system, which is why layer 2 exists for precisely the classes where a breach means notification duties rather than annoyance. Mitigations otherwise unchanged: no new public ports, read-only frontend key, immutable bronze, off-site encrypted backup as ransomware recovery.
- **Lock-in, honestly**: even all-FOSS, you're adopting formats. The exits are: S3 API (any store speaks it), parquet (every engine reads it), DuckLake catalog = plain SQL tables you can dump. MinIO's death this year is the object lesson — pick exits (formats), not vendors.

## 10. Observability

Feed the existing aspirant-monitor: per-source freshness age vs SLA; connector run success/duration/bytes; lake bytes by layer + `/data` `/scratch` SSD fill %; backup last-success/last-verify/last-drill ages; restic repo stats; orphan-blob count (inventory vs catalog sweep); small-file count in silver (compaction trigger); mdadm state; **SMART attributes — `smartmontools` is not installed today, so two 16-year-old disks are running blind; install it in week 1 regardless of everything else**; DuckDB query p95 on the frontend API; **replication-slot lag bytes on both source PGs (red alert well before `max_slot_wal_keep_size`)**; CDC end-to-end lag (source commit → bronze landing); dbt test pass-rate + run duration; Dagster asset freshness (which subsumes most per-source freshness checks once it lands).

## 11. Phasing

1. **Week 1 — stop the bleeding (no lake yet)**: smartmontools + SMART alerts; restic to `/scratch` + B2 for the precious set as it sits today; docker image prune; verify reMarkable sync (0 files in 30 d).
2. **Weeks 2-3**: Garage + DuckLake catalog + cron-driven ingest of the trivial connectors (pg dumps, rclone syncs of files/transcripts/cron-logs, browser_flows hook, cursor reads of `activity_log`/`request_log`); inventory table; backups extended over the lake.
3. **Weeks 4-5 — dbt + orchestrator**: dbt project over silver (CDC-less at first); Dagster OSS compose group absorbs the phase-2 crons; daily schedule + asset freshness.
4. **Weeks 6-7 — CDC spike, then rollout**: `wal_level=logical` change window on both PGs; dlt/`pgoutput` consumer spike on ONE mutable table (`tasks`); slot-lag alerting proven **before** widening the publication; then all mutable tables.
5. **Weeks 8-10**: extraction pipeline (text/OCR/transcripts/thumbnails); gold marts published to Postgres; Metabase; aspirant-explorer v1 (Overview, Datasets, Documents, Runs); restore drill #1; runbooks.
6. **Later**: search + provenance UI, ecosio drive ingest, curated Vue insights page, hardware refresh decision.

Each phase is a separate implementation epic with its own PRs; nothing here starts until the operator answers §12's top questions.

## 12. Questions the operator must answer

**Original top 3 — answered (operator, 2026-07-15):**

1. **Scope of "ALL my data" — YES, and wider than surveyed**: finance data, doctors' records, personal photos, personal emails, SMS/Telegram content "and more". Folded into §0.3 (sizing), §2 (mapping), §5g (sources), §9 (encryption), §14 (compliance).
2. **Backup / object-store path** — "Garage is fine", with an open option on building our own S3-parity server. Both paths compared in §3.5; recommendation is Path A (Garage) now, Path B a designed contingency with explicit triggers.
3. **RPO 24 h — YES.** Nightly cadence confirmed final (§6); last-24h losses replay from source systems.

**New blocking (raised by those answers):**

- **Q-N1 — Export mechanics for the personal sources** (§5g): photos (Google Takeout? iCloud? phone-side sync job?), email (which accounts; recurring IMAP vs one-off takeout), Telegram (desktop-client JSON export is the assumed path), SMS (Android XML backup app?), doctors/finance records (paper scans? portal PDFs?). Each answer determines its connector; none of these sources exist on any fleet host yet.
- **Q-N2 — Jurisdiction**: EU (GDPR at least in spirit) or US (state breach laws, HIPAA-adjacent)? §14 is written jurisdiction-agnostic and needs this to firm up.
- **Q-N3 — Key custody** (§9): where does the KEK live (password manager / hardware token / printed copy in a safe), and which LUKS unattended-reboot story (on-site USB key, manual SSH unlock, clevis/tang)? Encryption cannot ship without this decision.
- **Q-N4 — Message retention window** (§14): keep third-party correspondence forever, or window it (e.g. 5-year rolling for SMS/Telegram, forever for flagged threads)?

**The rest (grouped):**

- *Retention*: keep every bronze browser-flow scrape forever (~1.5 G/yr — probably yes) or window it? Pg dump retention ladder (e.g. 30 daily / 12 monthly / ∞ yearly)? What's deletable at 80% disk fill, and does an automated policy get to act, or only alert?
- *Legal/PII*: finance transactions, property valuations, voice messages (other people's voices — consent?), `banned_books` (jurisdiction?): any data that must be encrypted, retention-limited, or kept OUT of the centralized bag? GDPR-style erasure: if some future app stores other people's data, immutable bronze needs a crypto-erasure design — cheaper to decide now. **Pane transcripts specifically**: they can contain pasted secrets, tokens, and third-party content — ingest as-is, redact at ingest, or exclude?
- *CDC (§5c)*: acceptable end-to-end lag — is minutes fine (micro-batch) or is it truly per-write streaming? Who schedules the `wal_level=logical` restart windows on each PG? Confirm the hybrid split (CDC only for mutable tables, cursor for append-only) or insist on CDC-everything? What `max_slot_wal_keep_size` cap = how much WAL you'll trade for consumer downtime before the slot self-destructs?
- *Orchestrator/dbt*: is a web UI on the cell's internal network acceptable for Dagster/Metabase (auth story)? Who owns dbt model review — agents PR, operator merges?
- *Ownership & evolution*: who owns the catalog schema when it evolves — is future-you willing to be the DBA, or should schema changes be agent-run with review? Who patches Garage/DuckDB quarterly?
- *Access*: is the operator the only reader, or do agents (advisor, finance, commander) get read keys? Does anything ever *write back* (lake becomes system of record)? — recommend no for v1.
- *Frontend*: reuse aspirant-server auth? Any need for access from outside the LAN (→ tunnel vs auth hardening)?
- *Hardware*: appetite to replace the 2010 WD Greens (both mirror members are the same age/model — correlated failure) with one modern 4 TB pair, ~decides the "what when 2 TB fills" question for a decade? Fate of `/scratch`'s lone disk? LUKS at rest?
- *Sources*: is reMarkable sync supposed to be live (30 d silence)? Is `banned_books` re-acquirable or precious? Should kiwix ZIM updates (new monthly editions) be automated or manual?
- *Migration order*: proposal — backups → pg → files → browser_flows → remarkable → ecosio → (decision) workstation. Veto/reorder?

## 13. Unknown unknowns — what you weren't asking

- **You asked for a lake; your burning need is a backup.** Nothing irreplaceable on this cell survives a single `rm -rf`, ransomware event, or dual-disk failure today. Hence §11 phase 1.
- **A lake is not a warehouse.** Lake = cheap storage of everything in open formats, schema-on-read; warehouse = curated schema-on-write serving known questions. Medallion's silver/gold IS the warehouse-ization of the lake. You're building a small lakehouse; the gold layer is where warehouse discipline applies.
- **Query performance at "2 TB" is a red herring at 15 GiB RAM and ~GB data.** DuckDB scans parquet at disk speed; your gold layer will answer in milliseconds. The real ceiling is the WD Greens' ~100 MB/s sequential and dreadful random I/O — which is why catalog/metadata go on SSD and why full-scan patterns stay in gold-sized data.
- **Cataloging is a tax you pay forever.** Every source added = connector + inventory + freshness SLA + backup scope + restore-drill coverage. The §10 metrics automate the audit, but each new surface is a standing cost — that's the honest price of "single storage for ALL data".
- **The medallion's dirty secret for personal data**: most value sits in *silver* (searchable text, typed transactions, inventory), not gold. Don't over-invest in marts before search works.
- **Correlated infrastructure**: lake, catalog, backups tier-1, and producers all share one host, one PSU, one building (and now, via §5b, the workstation joins the same fire domain). Tier-2 off-site is the only uncorrelated copy — treat its health metric as the single most important number on the Overview page.
- **CDC imports a failure mode INTO your production databases.** A dead consumer pins WAL via its replication slot until the source DB's disk fills (§5c). Snapshot-based ingestion can only lose lake freshness; CDC done carelessly can take down the thing it observes. This asymmetry is why the design gates CDC behind proven slot-lag alerting, caps slot WAL, and keeps the dump lane running underneath forever.
- **The lake will observe the system that builds it.** Once system_3's activity_log, transcripts, and request_log are silver tables, the operator can query agent behavior with SQL joins instead of psql archaeology — likely the single highest-insight-per-byte source in the whole design. But it also means agent mistakes (this session included) become permanent, queryable history: decide deliberately that that's wanted.
- **Agents reading personal data is a boundary decision, not a technical one.** Once photos, messages, and medical records sit in the same lake the fleet's agents can query, "does the advisor get a read key" (§12) stops being an access-control detail and becomes the operator's most consequential privacy decision. The design defaults every agent to *no* access to `sensitivity=high` classes; each grant should be explicit, per-agent, per-class, and logged.

## 14. Compliance & legal posture (added 2026-07-15)

The confirmed scope makes this a personal archive containing **GDPR Art. 9 special-category data** (health records), financial records, message archives full of **third-party PII** (every correspondent, by construction), and photos of identifiable people (biometric-adjacent under GDPR/BIPA-style regimes).

- **The honest baseline**: a private individual holding their own records for personal use generally falls under GDPR's household exemption (Art. 2(2)(c)), and HIPAA binds covered entities, not patients holding their own charts. The *formal* obligations are therefore lighter than the raw category list suggests — but the design targets GDPR-grade controls anyway, for three reasons: (1) the exemption erodes the moment data is shared, published, or processed by something that looks like a service — autonomous agents acting on the data may already blur that line; (2) breach *harm* (identity theft from tax records, disclosure of health facts, other people's private messages) is real regardless of which statute applies; (3) controls are an order of magnitude cheaper designed-in than retrofitted. (assumption — jurisdiction unconfirmed, §12 Q-N2; if EU residence/processing applies, revisit formally.)
- **Duties designed in, mapped to mechanisms**: encryption at rest for special-category classes (§9 layer 2); **crypto-erasure** as the deletion mechanism compatible with immutable bronze (§9 layer 3); data minimization at ingest (transcript redaction filter before bronze; message-attachment triage); access logging on every `sensitivity=high` read (explorer API records actor, object, timestamp → §10 metrics).
- **Breach-notification playbook** (a runbook shipped with phase-1 docs, not an aspiration): detect (integrity + access-anomaly alerts, §10) → contain (revoke Garage keys, stop explorer, isolate cell from WAN) → assess scope from access logs + inventory sensitivity tags → notify within the applicable clock (GDPR: 72 h to the authority where it applies; US state breach statutes for financial data) → rotate KEK, restore from verified backup → post-mortem to the corpus.
- **Retention as a liability choice**: medical + finance default to keep-forever-encrypted (it is the operator's own archive); third-party-heavy classes (messages) get an operator-chosen retention window (§12 Q-N4) — holding twenty years of other people's correspondence is a liability decision, not a storage question.
