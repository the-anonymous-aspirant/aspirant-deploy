# Lake Skeleton — Garage + DuckLake on scratch storage

Phase-0 substrate for the walkable data-lake interface
(`docs/data-lake-design/DATA_LAKE_DESIGN.md` §11.1 phase 0).

This stack exists so the operator can click through `aspirant-explorer` and
disagree with it while disagreement is still cheap. It holds **only
obviously-synthetic fixtures**, and it is built to be thrown away.

---

## Why it is safe to run this before encryption exists

§11.0 binds: *real personal data must not land on unencrypted storage*, and a
populated disk cannot be encrypted in place. The skeleton is exempt not by
permission but by construction — three properties, each one structural rather
than a matter of discipline:

| Guardrail | How it is enforced |
|---|---|
| Storage is a scratch path expected to be destroyed | Everything lives under `/scratch/lake-skeleton/`. `lake-skeleton.sh` **refuses to start** if `LAKE_SKELETON_ROOT` points at `/data`, the real lake's volume. |
| Nothing real can arrive quietly | Fixtures are self-labelling (`SYNTHETIC — Ada Notarealperson`, dates in 2999, `FAKE-RECORD-00n`). The acceptance check fails if any fixture row stops looking fake. |
| The skeleton cannot outlive itself | Separate compose project (`aspirant-lake-skeleton`), so the `*/5` auto-pull cron that re-ups the production project can neither upgrade it nor resurrect it after teardown. `destroy` removes containers, volumes, and the scratch tree. |

**The moment you want to demo with a real medical PDF, phase 0b is due** — that
is §11.0's stated trigger, not an exception to be made once.

---

## Shape

Three services on a project-local bridge network, **no host ports** (§4 — the
cell's 80/8081/8999 are already internet-exposed and the lake must not join
them):

| Service | Image | Role |
|---|---|---|
| `garage` | `ghcr.io/the-anonymous-aspirant/garage:v2.3.0` | S3 object store. Data + metadata both on scratch. |
| `catalog` | `ghcr.io/the-anonymous-aspirant/lake-catalog-postgres:16-alpine` | DuckLake catalog database (`lake_catalog_skeleton`). |
| `duckdb` | `ghcr.io/the-anonymous-aspirant/aspirant-lake-duckdb:1.5.4` | On-demand DuckDB client (`client` profile); the query engine, not a server. |

All three are GHCR mirrors of upstream. The cell cannot reach Docker Hub — its
Wi-Fi dongle TLS-times-out against `registry-1.docker.io` while GHCR answers in
under a second — so upstream images are mirrored from the dev box and pinned.
Pinning also keeps the stack off the surprise-upgrade path §4 warns about.

### Versions and why these ones

| Component | Pin | Source |
|---|---|---|
| Garage | `v2.3.0` | Current stable per the [Garage quick-start](https://garagehq.deuxfleurs.fr/documentation/quick-start/); latest semver tag on Docker Hub. |
| DuckDB | `1.5.4` | Current stable. DuckLake v1.0 requires ≥ 1.5.2. |
| DuckLake | v1.0 | [ducklake.select](https://ducklake.select/) stable. |
| Catalog Postgres | `16-alpine` | Matches the fleet's existing Postgres major. |

### Two deliberate divergences from the design spec

1. **Separate compose file, not a `lake` service group in `docker-compose.yml`**
   (§4 says the latter). Teardown becomes `compose down -v` instead of a diff
   against the production stack, and the auto-pull cron cannot touch it. §4's
   substantive requirements — pinned images, docker-network only, no new public
   ports — are all honoured. When the *real* lake ships, it should follow §4 and
   live in the production compose; this divergence is skeleton-only.

2. **Garage metadata on the scratch spindle, not the SSD LV** (§4 wants the LV,
   because metadata is hot random I/O and the `/data` disks are 2010-era WD
   Greens). Carving an LV for a stack whose purpose is to be destroyed would
   leave state outside the one path we intend to delete. Performance is
   irrelevant at fixture scale. The real lake should take §4's advice.

---

## Operating it

Run from a checkout on the cell (`~/aspirant-deploy` post-merge):

```bash
scripts/lake-skeleton.sh up       # start + bootstrap bucket, key, catalog
scripts/lake-skeleton.sh verify   # acceptance checks
scripts/lake-skeleton.sh status   # containers, published ports, disk use
scripts/lake-skeleton.sh down     # stop, keep data
scripts/lake-skeleton.sh destroy  # stop and delete every byte it owns
```

`up` is idempotent: it generates `garage.toml` and the credentials env-file only
when absent, assigns a Garage cluster layout only when the node has no role yet,
and creates the bucket and access key only when they do not already exist.

Credentials (Garage access key, catalog password) are generated at `up` and
written to `/scratch/lake-skeleton/lake-skeleton.env`, mode 600. They live on
the scratch path with everything else, so `destroy` takes them too — a fresh
`up` mints new ones. Nothing here is a secret worth keeping; the stack it
authenticates holds only fixtures.

### What `verify` proves

1. The Garage bucket round-trips an object byte-identically.
2. The DuckLake catalog is queryable via DuckDB through the Postgres catalog.
3. **Parquet actually landed in Garage** — asserted by listing the bucket, not
   inferred from a successful `SELECT`, which would not distinguish a real S3
   write from a local spill.
4. Catalog metadata really lives in Postgres (`ducklake_*` tables), which is
   what makes the lake multiplayer (§7) and what the explorer will attach to.
5. Snapshots are recorded — time-travel is the skeleton's stand-in for object
   versioning (§7).
6. Every fixture row is still self-labelling as synthetic (§11.0).

---

## Teardown, and why it is an acceptance criterion

The skeleton's safety argument is only as good as its disposability, so
disposability is tested rather than asserted:

```bash
scripts/lake-skeleton.sh destroy
ls /scratch/lake-skeleton          # must not exist
docker ps -a --filter name=lake-skeleton-   # must be empty
scripts/lake-skeleton.sh up && scripts/lake-skeleton.sh verify   # green again
```

A skeleton that cannot be recreated from an empty scratch path is one whose
state has quietly leaked somewhere else — which is exactly the failure §11.0
warns about. Run the destroy-and-recreate cycle whenever the stack's definition
changes, not only the first time.

`destroy` uses `sudo rm -rf` on the scratch tree: Postgres and Garage write as
their own container users, so the tree is not owned by the invoking user.

---

## What this is not

- **Not the real lake.** No connector points at it, no real source writes to it,
  and nothing it holds is backed up — by design (§6 backups protect data that
  exists; fixtures are regenerable).
- **Not a persistence guarantee.** Treat every `up` as potentially starting from
  nothing. If a fixture matters enough to preserve, it belongs in the repo as
  seed code, not in the skeleton's storage.
- **Not reachable from production.** It is on its own bridge network,
  deliberately not attached to `aspirant-online_default` (§9 threat model).
