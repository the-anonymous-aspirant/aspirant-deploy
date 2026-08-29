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

All three come from GHCR. The cell cannot reach Docker Hub — its Wi-Fi dongle
TLS-times-out against `registry-1.docker.io` while GHCR answers in under a
second — so images are staged from the dev box and pinned by digest. Pinning
also keeps the stack off the surprise-upgrade path §4 warns about.

**Two of the three are mirrors; the third is ours.** `garage` and `catalog` are
registry-to-registry copies of upstream tags — upgrading either means
re-mirroring. `aspirant-lake-duckdb` is **built from this repo's
`Dockerfile-LakeDuckDB`**, which makes it the only image here whose source can
change under a normal PR. Editing that Dockerfile changes what the repo
declares; the digest above keeps serving whatever was last pushed, and nothing
in the deploy path notices the gap. See § Republishing the client image — the
step is part of the same PR as the Dockerfile edit, not a follow-up.

### Versions and why these ones

| Component | Pin | Source |
|---|---|---|
| Garage | `v2.3.0` | Current stable per the [Garage quick-start](https://garagehq.deuxfleurs.fr/documentation/quick-start/); latest semver tag on Docker Hub. |
| DuckDB | `1.5.4` | Current stable. DuckLake v1.0 requires ≥ 1.5.2. |
| DuckLake | v1.0 | [ducklake.select](https://ducklake.select/) stable. |
| Catalog Postgres | `16-alpine` | Matches the fleet's existing Postgres major. |

### Republishing the client image

Any change to `Dockerfile-LakeDuckDB` — a pip pin, a baked extension, the base
tag — takes effect only when the image is rebuilt, pushed, and the digest in
`docker-compose.lake-skeleton.yml` is updated. All three, in the PR that edits
the Dockerfile. A Dockerfile edit without them is a no-op that reads like a
change.

`scripts/publish-lake-client.sh` does all four, in order, as one command
(#4441). Use it rather than the steps by hand: the repin is not a step you can
forget in it, because the push and the repin are the same action.

```bash
# Build a candidate and check it BEFORE it is anywhere public. Needs no
# credential; safe for anyone, including an agent, to run.
./scripts/publish-lake-client.sh

# Read the outward-facing half without running any of it.
./scripts/publish-lake-client.sh --push --dry-run

# Build, verify, publish, repin docker-compose.lake-skeleton.yml, re-verify.
# Refuses up front unless the gh token carries write:packages.
./scripts/publish-lake-client.sh --push
```

Then commit the `docker-compose.lake-skeleton.yml` change the script wrote —
the push is only half of the landing.

The tag tracks the DuckDB version, and the script **derives** it from the
`duckdb==` pin in `Dockerfile-LakeDuckDB` rather than taking it as an
argument, so a `duckdb==` bump automatically means a new tag as well as a new
digest. A hand-typed tag is how one tag comes to name two images, which is how
the pin stops being a rollback point.

<details>
<summary>The same four steps by hand, if the script is unavailable</summary>

```bash
# 1. Build, and check the result BEFORE it is anywhere public.
docker build -f Dockerfile-LakeDuckDB -t aspirant-lake-duckdb:candidate .
LAKE_CLIENT_IMAGE=aspirant-lake-duckdb:candidate ./tests/lake_client_image_unit.sh

# 2. Publish. Needs a GHCR credential with write:packages — an outward-facing
#    step, and the one part of this an agent does not do unasked.
docker tag aspirant-lake-duckdb:candidate \
  ghcr.io/the-anonymous-aspirant/aspirant-lake-duckdb:<duckdb-version>
docker push ghcr.io/the-anonymous-aspirant/aspirant-lake-duckdb:<duckdb-version>

# 3. Repin: put the published digest in docker-compose.lake-skeleton.yml.
docker buildx imagetools inspect \
  ghcr.io/the-anonymous-aspirant/aspirant-lake-duckdb:<duckdb-version> \
  --format '{{.Manifest.Digest}}'

# 4. Confirm the pin, not the local build, is what now satisfies the Dockerfile.
./tests/lake_client_image_unit.sh
```

</details>

### Why the publish is gated and the repin is not

Pushing to GHCR is outward-facing, so `--push` needs both an explicit flag and
a `write:packages` scope on the `gh` token, and it checks for the scope
*before* it builds — a refusal costs nothing and writes nothing. As of
2026-08-28 that scope is absent on this box (`gh auth status` reports `gist`,
`read:org`, `repo`), which is the still-open operator question in
`docs/IMAGE_PUBLISH_DECISION.md` §2. Until it is provisioned, `--push` refuses
and says so; `--dry-run` still prints the whole plan.

The repin is deliberately *not* gated behind anything extra: it is the step
that was skipped, and welding it to the push is the entire point of the
script. `tests/lake_client_publish_unit.sh` asserts both halves — that a
credential-less `--push` touches neither docker nor the compose file, and that
the digest surgery hits only the lake client's line and is idempotent.

`tests/lake_client_image_unit.sh` is what makes the omission loud: it probes the
**pinned** digest and fails when the published image is missing something the
Dockerfile declares. It went in after exactly that omission (#4290) — #4134 added
`cryptography==46.0.3` on 2026-08-24 and did not repin, so `seed` and `ingest`
both died at `import` inside the container for three days while every suite in
`tests/` stayed green. None of them had ever run the pinned image; they all
pip-install their dependencies into `python:3.11-slim` at test time.

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

### The explorer's read-only credentials

`up` issues **two** Garage keys and two catalog identities, not one:

| identity | grant | used by |
|---|---|---|
| `lake-skeleton-rw` | `RW` on the bronze bucket | fixtures, verify, the skeleton itself |
| `lake-skeleton-explorer-ro` | `R` only | `explorer-api` (the mediated bridge, #2409-D2) |
| `ducklake` | catalog owner | the skeleton |
| `explorer_ro` | `SELECT` only | `explorer-api` |

The read-only pair is what makes the lake bridge a mediated **read** path rather
than a mediated read-write one. That distinction is the basis on which the
bridge was authorised, so it is issued here rather than by hand.

It is issued here for a specific reason: both credentials once existed only as
manual artifacts on a single host. `destroy` and `up` is an acceptance
criterion of this skeleton — rebuilding is how its correctness is shown — so a
bound that lives in one machine's memory disappears on exactly the operation
this document tells you to perform, and nothing would have reported it.

`verify` proves the bound rather than restating it: it attempts a `PUT` with the
read-only key and a `CREATE TABLE` with the read-only role, and **fails if
either succeeds**. It also checks each can still read, because a credential that
can do nothing is a broken explorer wearing the costume of a working guardrail.

Credentials (Garage access keys, catalog passwords) are generated at `up` and
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

### What `verify-at-rest` proves (#4273)

`verify` above proves the skeleton is a working lake. `verify-at-rest` proves a
different, narrower thing: that what actually landed on disk is *encrypted*,
not merely that the pipeline that writes it claims to encrypt. It runs two
independently-executed checks and combines them into one verdict, because one
script cannot make both claims — see #4273-B1's task body for why the split is
by execution context, not tidiness:

**Layer 1 — is the volume itself encrypted?** Run on the **host**, as the
invoking user, via `cryptsetup`/`findmnt`/`lsblk` against the device backing
`$LAKE_SKELETON_ROOT` — resolved from the path, not from a hardcoded name
list, because the three-name list in `scripts/luks-layer1/postcheck.sh`
answers a different question (are the *real* lake's three ceremony volumes
mapped) that has no entry for this skeleton's root at all.

**Layer 2 — is what's stored actually ciphertext, and does it agree with the
catalog?** Run **inside the client container** (`scripts/lake_verify_at_rest.py`,
#4299), against the catalog and Garage directly — never through the explorer's
decrypting read path, which would report a plaintext write as encrypted. The
checks, numbered as the report prints them: **0** the catalog is not empty —
zero rows is a FAIL, never a vacuous green (#4524); **1** every `high` row
declares an envelope, and a `sensitivity` outside the catalog vocabulary fails
here and is checked as `high` from then on, fail closed (#4524); **2** the
stored object is `AOBJ` ciphertext; **3/3b** no plaintext hides under a `high`
row, no `normal` row carries a wrapped DEK, and the content address is compared
twice — whole object and past the header — which catches a forged five-byte
header over *this row's* plaintext, but not a forged header over other bytes
(#4301 F3: that is what check 6 is for); **4** the row's `kek_version` agrees
with the envelope header; **5** the DEK actually unwraps under the KEK in
custody; **6** with that DEK the stored object decrypts to the row's content
address — the one exact check, which no forgery shape survives (#4524); **7**
every object under `bronze/blobs/` has a catalog row, listed from the bucket
itself, so a blob nobody catalogued cannot hide from the catalog-driven checks
(#4524). When `LAKE_KEK_FINGERPRINT` is set the supplied KEK is checked against
it first: a mismatch is reported as an input error and the run is NOT GREEN,
rather than every `high` row reading as data loss under a mistyped key.

**A SKIP is never a PASS, on either layer.** Layer 1 SKIPs (rather than
failing outright) when the volume resolves but is not a LUKS mapping — the
expected, correct result for this skeleton, whose root is deliberately plain
`/scratch` (§11.0). Layer 2 SKIPs checks 5 and 6 when no KEK is in custody
for this run, and check 6 alone when a KEK is held but the image cannot
decrypt (#4290). Either SKIP keeps the combined verdict at NOT GREEN: the point of the
check is exactly to distinguish "provably encrypted" from "nobody looked", and
folding a SKIP into green would erase that distinction on the one surface that
exists to preserve it.

**Expected result on this skeleton today: NOT GREEN**, and that is the harness
working, not a bug to chase — `/scratch` is unencrypted by design (layer 1
SKIPs), and every `sensitivity=high` fixture is sealed under a throwaway KEK
that no longer exists anywhere (layer 2's check 5 fails). See #4299's findings
comment on the task for the live run this predicts.

---

## The fixture set

`scripts/lake-skeleton.sh seed` regenerates everything in one command. It is
idempotent — blobs are content-addressed so they land at the same key every
time, and the tables are replaced rather than appended to.

Layout follows §2's medallion mapping rather than approximating it: **binary
blobs live once in bronze**, content-addressed at
`bronze/blobs/sha256/ab/cd/<hash>`, and only their *derived artifacts* appear in
silver. A PDF is not copied three times to "promote" it.

**Bronze** — 8 content-addressed blobs: 2 PDFs, 2 images plus their 2
thumbnails, 1 WAV, 1 JSON message export. They are real files, not stand-ins:
the PNGs decode, the PDFs open to a page of visible text. Both are synthesized
in pure Python (`zlib` + `struct` for PNG, hand-written object syntax for PDF)
so the client image needs no image-processing stack for three fixture pictures.

**Silver** — `asset_inventory` (one row per blob: hash, key, source path, mime,
size, kind, **sensitivity**, ingest timestamp, run id, plus the phase-1
provenance columns — dataset id, sensitivity source, retention class,
jurisdiction, KEK version), `extracted_text`,
`image_metadata` (dimensions, camera, thumbnail ref), `audio_transcripts`,
`messages` (unified across telegram/sms/email per §2, with an attachment blob
ref), `finance_transactions` (a typed table export standing in for a Postgres
source), and `ingest_runs` (the connector ledger §8.6's page reads).

The schema of `asset_inventory` and `ingest_runs`, and the rule that decides a
blob's sensitivity at intake, are **not** declared here — they live in
`scripts/lake/catalog.py` and are shared with the real ingest runner (#4271) and
the explorer's real-record views (#4272). The seed imports them like every other
writer, so seeding exercises the real contract rather than a copy of it. See
[data-lake-design/REAL_DATA_CATALOG.md](data-lake-design/REAL_DATA_CATALOG.md).

**Gold** — `gold_finance_monthly`, `gold_timeline`, `gold_source_freshness`
(green/amber/red, which is what the Overview page renders).

§2 is explicit that `sensitivity=high` is **a column, not a folder convention**,
so the one high-sensitivity fixture (a synthetic medical note) sits at the same
path layout as everything else and differs only in that column. That is
deliberately the harder case for the explorer to get right.

### How "obviously fake" is enforced

Not by discipline — by a check that fails closed. `verify` walks every VARCHAR
column of every fixture table and asserts each distinct value is self-labelling:
it carries `SYNTHETIC`, `FAKE-`, or the impossible year `2999`, or it is a
structural value (a hash, an object key, or a known enum like `image/png`).
Anything else is reported as a leak and fails the run.

This matters more than it looks. The guardrail's real failure mode is not
someone loading a real medical PDF on day one — it is realism creeping in one
column at a time until a screenshot becomes ambiguous. A check that fails on
unrecognised prose catches that; a code review of the fixture file does not.

`verify` also asserts that every blob's bytes actually hash to its own key. A
blob whose content does not match its content address would make provenance
(§8.5) a lie, and the check is cheap.

Running `verify` on an **unseeded** stack skips the coverage block rather than
failing it — the teardown drill exercises exactly that state.

---

## Finding: DuckLake inlines small writes into the catalog by default

Discovered while building this stack, and it matters well beyond it.

DuckLake's data inlining is **on by default with a row limit of 10**
([docs](https://ducklake.select/docs/stable/duckdb/advanced_features/data_inlining)).
Writes under that limit are stored as rows in the catalog database and never
reach the object store at all. The first run of the acceptance check caught it
exactly this way: three fixture rows queried back perfectly while
`ducklake_data_file` was empty and the bucket held nothing under `bronze/`.

This stack therefore attaches with `DATA_INLINING_ROW_LIMIT 0`, and asserts the
result rather than trusting it.

**Why it matters for the real lake**, beyond making a test honest:

- §9's envelope encryption operates on objects the ingest-runner encrypts before
  `PUT`. Inlined rows never become objects, so with stock settings a small write
  of `sensitivity=high` data would land **unencrypted in the catalog Postgres**,
  bypassing layer 2 entirely. Crypto-erasure (destroy the wrapped DEK) would not
  reach it either.
- §6/§7 assume the catalog is small and the Postgres backup protects "the lake's
  brain", not its body. Inlining silently makes the catalog hold data.
- §9's exit story rests on data being parquet any engine can read. Inlined rows
  are DuckLake-internal tables.

None of this is a DuckLake defect — inlining is a sensible small-write
optimization. But the encryption design assumes object-store-or-nothing, so
whichever epic implements the real ingest path should set the inlining limit
explicitly and assert on `ducklake_data_file`, exactly as `verify` does here.

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
