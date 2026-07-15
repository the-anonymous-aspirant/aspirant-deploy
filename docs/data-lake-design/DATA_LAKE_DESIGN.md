# Aspirant Data Lake — Design Spec

*Task #2149 · 2026-07-15 · Status: design for operator review, no implementation yet.*
*Companion: [SURVEY.md](./SURVEY.md) — full Phase-1 storage-surface inventory with raw evidence.*

## 0. The two corrections that shape everything

1. **The cell has 15 GiB of RAM, not 2 TB.** The 2 TB is storage: a 1.8 TiB RAID1 pair (`/data`, 8% used), a 916 GiB empty scratch disk, and a 233 GiB SSD with ~131 GiB unallocated. 15 GiB RAM rules out Spark/Trino/Hive-class engines and makes DuckDB-class embedded engines the only sane choice. This is a feature: at your scale, the heavyweight stack is pure liability.

2. **Your precious data is ~2 GiB, growing < 2 GiB/year — and it has zero backups.** Of 124 GiB on `/data`, 122 GiB is re-downloadable cache (a Wikipedia ZIM + Ollama models). The irreplaceable set — reMarkable notebooks (1.4 G), user files/valuations/finance reports, advisor uploads, audio, and a 31 MB Postgres — is protected today only by RAID1 across two ~2010-era WD Green drives of the same model and age (correlated-failure risk), with no protection at all against deletion, corruption, ransomware, or fire. **The most valuable 20% of this project is the backup subsystem, and it should ship first.** A data lake is not a backup, and a backup is not a data lake; this design delivers both, in that order.

## 1. Architecture overview

```
producers (unchanged)                 lake (new, additive)
─────────────────────                ────────────────────────────────
postgres ──pg_dump──────┐            ┌─ S3 object store (Garage, /data)
/data/aspirant/* ─rclone┤            │   bronze/  raw, immutable
browser_flows cron ─────┼─ ingest ──▶│   silver/  parquet (DuckLake tables)
ecosio drive (manual) ──┘  runner    │   gold/    curated marts
                                     ├─ DuckLake catalog (existing Postgres)
                                     ├─ backup: restic → /scratch + off-cell
                                     └─ aspirant-explorer frontend (read-only)
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

## 6. Backup strategy (ships before the lake proper)

3-2-1 with the precious set (~3 GiB incl. dumps) so small that every option is cheap:

- **Tier 1 — nightly, on-cell, cross-disk**: `restic` repo on `/scratch` (916 G idle, physically separate disk). Scope: bronze bucket + pg dumps + DuckLake catalog dump + `/data/aspirant` precious dirs (belt-and-suspenders during migration). Restic gives encryption, dedup, and content checksums ([restic docs](https://restic.readthedocs.io/)). `/scratch` is a lone elderly disk — it is a second copy, not an archive.
- **Tier 2 — nightly, off-cell**: same restic repo replicated to an off-site S3 target (Backblaze B2 ≈ $6/TB-month — assumption, verify current pricing; ~3 GiB ⇒ pennies) **or** pull-based to the workstation's external drive. Recommend B2: the external drive is intermittently mounted and lives in the same building (fire domain).
- **Integrity**: `restic check` weekly; `restic check --read-data` monthly (this is what catches silent bit-rot on old drives); alert if last-success age > 26 h.
- **Restore drill**: quarterly, scripted: restore to `/scratch/restore-test`, `pg_restore` into a scratch DB, run 5 smoke queries, diff inventory counts. **An untested backup is a hypothesis, not a backup.** The drill is a cron with a red alert on failure, not a calendar intention.
- **Rollback plan** (lake itself): connectors are read-only; to abandon, stop the lake compose group and delete `/data/lake` — no producer notices. Keep the pre-lake `rsync` snapshot of `/data/aspirant` on `/scratch` for the first 90 days.

RPO today is ∞. Proposed: RPO 24 h / RTO half a day — operator must confirm (§10 Q3).

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

Auth: reuse aspirant-server's session/user model (operator decision §10 Q9); served on the internal network only, never on the public :80.

## 9. Access control, secrets, lock-in

- **Keys**: per-connector Garage key pairs — ingest keys write-only to bronze/silver; frontend/API key read-only; admin key offline. Rotation is a documented 5-minute runbook, semiannual + on-compromise.
- **Secrets**: compose env-files as today; note the existing pattern (DB password readable in container env) is the real weak point — worth a follow-up hardening task independent of the lake.
- **Encryption**: at rest — restic backups are always encrypted; whole-disk LUKS for `/data` is an operator decision with a real cost (unattended-reboot keying) (§10 Q8). In transit — everything is on-host docker networks; remote human access via SSH tunnel only.
- **Threat model note**: centralization concentrates blast radius. The box already exposes :80/:8081/:8999 to the internet; the lake makes it the highest-value target in the fleet. Mitigations: no new public ports, read-only frontend key, immutable bronze, and the off-site encrypted backup as ransomware recovery.
- **Lock-in, honestly**: even all-FOSS, you're adopting formats. The exits are: S3 API (any store speaks it), parquet (every engine reads it), DuckLake catalog = plain SQL tables you can dump. MinIO's death this year is the object lesson — pick exits (formats), not vendors.

## 10. Observability

Feed the existing aspirant-monitor: per-source freshness age vs SLA; connector run success/duration/bytes; lake bytes by layer + `/data` `/scratch` SSD fill %; backup last-success/last-verify/last-drill ages; restic repo stats; orphan-blob count (inventory vs catalog sweep); small-file count in silver (compaction trigger); mdadm state; **SMART attributes — `smartmontools` is not installed today, so two 16-year-old disks are running blind; install it in week 1 regardless of everything else**; DuckDB query p95 on the frontend API.

## 11. Phasing

1. **Week 1 — stop the bleeding (no lake yet)**: smartmontools + SMART alerts; restic to `/scratch` + B2 for the precious set as it sits today; docker image prune; verify reMarkable sync (0 files in 30 d).
2. **Weeks 2-3**: Garage + DuckLake catalog + ingest-runner with the trivial connectors (pg dumps, rclone syncs, browser_flows hook); inventory table; backups extended over the lake.
3. **Weeks 4-6**: extraction pipeline (text/OCR/transcripts/thumbnails); silver tables; first gold marts (finance).
4. **Weeks 7-9**: aspirant-explorer v1 (Overview, Datasets, Documents, Runs); restore drill #1; runbooks.
5. **Later**: search + provenance UI, ecosio drive ingest, log ingestion, hardware refresh decision.

Each phase is a separate implementation epic with its own PRs; nothing here starts until the operator answers §12's top questions.

## 12. Questions the operator must answer

**Top 3 (blocking):**

1. **Scope of "ALL my data"** — the cell is the *smallest* island. Does the lake eventually ingest: the workstation (`isa`) home dir + repos, system_3's Postgres (12.8 M-row activity_log dwarfs everything here), phone photos/messages, cloud accounts (Gmail/Drive/GitHub), email archives, the ecosio drive? The answer changes sizing, legal exposure, and connector roadmap more than any other input.
2. **Off-site backup target + budget** — B2/S3 (recommended, ~pennies/month at 3 GiB) vs pull-to-workstation-drive vs both? Backup can't ship without this.
3. **RPO/RTO** — is losing 24 h of data acceptable (nightly cadence), or do finance/notebook writes need tighter? Is half-a-day restore acceptable?

**The rest (grouped):**

- *Retention*: keep every bronze browser-flow scrape forever (~1.5 G/yr — probably yes) or window it? Pg dump retention ladder (e.g. 30 daily / 12 monthly / ∞ yearly)? What's deletable at 80% disk fill, and does an automated policy get to act, or only alert?
- *Legal/PII*: finance transactions, property valuations, voice messages (other people's voices — consent?), `banned_books` (jurisdiction?): any data that must be encrypted, retention-limited, or kept OUT of the centralized bag? GDPR-style erasure: if some future app stores other people's data, immutable bronze needs a crypto-erasure design — cheaper to decide now.
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
- **Correlated infrastructure**: lake, catalog, backups tier-1, and producers all share one host, one PSU, one building. Tier-2 off-site is the only uncorrelated copy — treat its health metric as the single most important number on the Overview page.
