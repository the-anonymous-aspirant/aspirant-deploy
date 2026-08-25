# The real-data ingest runner

Task #4271 (`#4238-B1`), layer 1 of the phase-1 real-data epic (system_3 #4238).
Implemented by `scripts/lake_ingest.py`; tested by `tests/lake_ingest_unit.sh`.

DATA_LAKE_DESIGN.md §2 (bronze blobs + blob catalog), §8.6 (connector ledger),
§9 (layer 2 envelope encryption). That document is substrate-resident, not a
file in this repo — see `aspirant-deploy-conventions-and-lake-design-source`.

Reads the catalog contract from `scripts/lake/catalog.py` (#4270,
`REAL_DATA_CATALOG.md`) and the object crypto from `scripts/kek/` (#4133/#4134,
`KEK_CEREMONY.md`). It re-derives neither, and `tests/lake_ingest_unit.sh`
asserts that it still does not.

## Why this is a second writer, not a flag on the first

`scripts/lake_skeleton_fixtures.py` already PUTs blobs to Garage and writes
`asset_inventory`. Adding `--real` to it would have been a smaller diff and the
wrong one.

The fixtures loader's safety property is that everything it writes is
*unmistakably fake* — §11.0's guardrail, enforced down to the 2999 dates and the
`SYNTHETIC — ` prefixes. That property is what makes it safe to run anywhere, on
any host, by anyone reading `LAKE_SKELETON.md`. A `--real` switch would put that
guarantee one flag away from being off, on the one script most likely to be run
casually.

So there are two writers. They share the two things that must never fork — the
catalog contract and the envelope crypto — and differ in everything else:
`seed` authors its own bytes and replaces its tables; `ingest` reads bytes it did
not author and appends to a catalog that already holds rows it did not write.

## Running it

```
scripts/lake-skeleton.sh ingest path/to/manifest.json            # load
scripts/lake-skeleton.sh ingest path/to/manifest.json --dry-run  # report only
```

The manifest's own directory is bind-mounted **read-only** at `/source` in the
client container, so relative record paths resolve inside the container exactly
as they do on the host. Read-only is not a formality: an ingest that could write
to the source tree could damage the only copy of the data it is reading.

Directly, outside compose: `python scripts/lake_ingest.py <manifest> [--dry-run]`,
with `LAKE_S3_*`, `AWS_*`, `LAKE_CATALOG_DSN` and (for `high` records)
`LAKE_KEK_HEX` in the environment — the same variables the fixtures loader reads.

## The manifest

```json
{
  "dataset_id": "DS-2026-0001",
  "source": "operator-laptop-documents",
  "retention_class": "keep-forever",
  "jurisdiction": "EU",
  "root": "/optional/explicit/base/path",
  "records": [
    {"path": "documents/tax-2019.pdf", "sensitivity": "high"},
    {"path": "photos/holiday-01.jpg",  "sensitivity": "normal"},
    {"path": "exports/telegram.json",  "sensitivity": "normal",
     "mime": "application/json", "kind": "message_export"}
  ]
}
```

| field | required | meaning |
|---|---|---|
| `dataset_id` | yes | Joins the load back to the operator's #4238-A1 intake record. Written to every row. |
| `source` | yes | Names the load in the §8.6 run ledger. |
| `records[].path` | yes | Absolute, or relative to `root` (default: the manifest's own directory). Recorded in `source_path` **as declared**, not as resolved — provenance is the path the operator knows, not the one this process happened to open. |
| `records[].sensitivity` | no | `high` / `normal`. **Omitting it means `high`** — see below. |
| `records[].mime` | no | Guessed from the extension, else `application/octet-stream`. |
| `records[].kind` | no | Derived coarsely from the MIME type (`image` / `audio` / `video` / `document` / `blob`). Deliberately coarse: guessing finely produces confident wrong answers, and an honest `blob` beats a wrong `document`. |
| `retention_class`, `jurisdiction` | no | Default to the operator's 2026-07-18 standing ruling via `catalog.py`. Per-dataset, because a dataset may narrow them in its intake record. |

Validation is strict and happens before the first byte is read. Every check is
one the runner would otherwise hit mid-load, and a manifest typo found on record
6,000 costs the operator a half-loaded lake, while the same typo found before
the first PUT costs them an edit.

## The three properties worth knowing

### 1. Fail closed, twice

Sensitivity comes from `catalog.resolve_sensitivity`, which resolves anything it
cannot confidently read as `normal` to `high` (the full table is in
`REAL_DATA_CATALOG.md`). A `high` blob is envelope-encrypted before it reaches
Garage, and with no KEK loaded the run **refuses**:

- **Pre-flight** — before any file is opened, the runner asks whether the
  manifest contains *any* record that resolves to `high`. If it does and no KEK
  is loaded, it refuses the whole run and writes nothing.
- **At the write** — the same refusal, re-checked against the resolved decision
  for the record actually in hand, so no future refactor of the pre-flight can
  quietly let a `high` blob past.

The pre-flight is the one that matters operationally. Under the fail-closed
intake rule an *undeclared* record is `high`, so a manifest with no sensitivity
field at all needs a KEK for every line — and a run that discovered that on
record 4,000 of 10,000 would already have written 3,999 objects the operator now
has to reason about.

Fail-closed is not fail-always: a manifest of purely `normal` records
legitimately needs no key and loads without one.

### 2. The catalog row is the commit marker

Per record, the object is PUT **and then** the `asset_inventory` row is written,
and a re-run skips on the presence of the row.

Ordered the other way, a crash between the two steps would leave a row promising
an object that is not there — a silent hole a reader discovers years later.
Ordered this way, a crash leaves an orphan object that the next run overwrites at
the identical (content-addressed) key, with a row written in the same iteration
that matches it.

This is also why a re-run must **skip** rather than blindly re-PUT. Re-encrypting
a `high` blob mints a fresh DEK, so the *existing* row's `wrapped_dek` would no
longer open the *new* object. Overwriting a good ciphertext with another good
ciphertext is still data loss if the catalog is left pointing at the wrong key.
`tests/lake_ingest_roundtrip.py` asserts the strong form of this: a second run
issues **no** `put_object` at all, not merely that the row count is unchanged.

### 3. One bad record does not lose the other ninety-nine

An unreadable file is counted, named by its `source_path` so it can be found
afterwards, and stepped over; the records behind it still load and the run lands
in the ledger as `partial`.

What is *not* tolerated is a systemic refusal — no KEK — which aborts, because
retrying it ten thousand times produces ten thousand identical failures and no
data.

## Idempotence keys on `sha256`, globally

§2 defines `asset_inventory` as one row per content-addressed bronze blob, so
"have I already loaded this?" is a question about the blob, not about the blob
*within this dataset*.

The consequence is worth stating rather than discovering: **a byte-identical
file present in two datasets is stored once and catalogued once, under whichever
dataset loaded it first**; the second run counts it as a skip. De-duplication is
the point of content-addressing, so this follows the existing contract — but it
does mean `dataset_id` answers "which load first brought these bytes in", not
"every dataset that contains them". The same collapse happens *within* a single
manifest that names the same bytes twice.

The skip set is read once per run (`SELECT sha256 FROM asset_inventory`) rather
than point-queried per record: DuckDB has no index here, so a per-record
`WHERE sha256 = ?` is a full scan each time, which turns a re-run into
O(records × rows). At 64 chars a digest, a million blobs is ~70MB resident —
acceptable now, and the line to revisit if the lake outgrows it.

## Run outcomes

Every run writes exactly one `ingest_runs` row, including a run that refused.
"No run row" and "a run that declined to write unencrypted data" are very
different facts, and the operator reads only one surface.

| `status` | means | exit code |
|---|---|---|
| `success` | Every record loaded or was already present. | 0 |
| `partial` | At least one record could not be read; the rest loaded. | 1 |
| `failed` | The run refused outright (no KEK for a `high` record). Nothing was written. | 3 |

A manifest that does not parse exits 2 without writing a ledger row — there was
no run to record.

A re-run of an already-complete manifest is `success`, not `partial`: *already
loaded* is not a failure. Its ledger row carries `files_seen = N` with
`objects_high = objects_normal = bytes_ingested = 0`, which is how a reader
distinguishes it from a first load. There is no `objects_skipped` column, and
this runner did not add one — the #4270 contract had just been sealed and is
read from another repo by #4238-B2; the skip count is derivable from the columns
that already exist.

## What this subtask did NOT do

Load real bytes. #4271 builds and tests the runner against synthetic and sample
input only. The first real load is #4238-D1, gated on the operator's #4238-A1
dataset record, and the live Garage hop is that task's joint acceptance with the
explorer read half (#4238-B2). Nothing here has been run against `/data`.

## Testing

`./tests/lake_ingest_unit.sh` — two suites.

The **host** suite needs no docker. It asserts the structural property the
round-trip cannot: that the runner still imports the catalog contract and the
envelope gate rather than growing its own copy, that the compose mounts it
depends on are present, and that this document exists. A local re-derivation of
the crypto or the DDL would pass every behavioural test while forking the
contract — which is exactly the drift #4270 moved the schema out of the fixtures
loader to prevent.

The **container** suite (`python:3.11-slim` + `cryptography boto3 moto duckdb`)
drives the runner end-to-end: `moto` stands in for Garage, and a real in-memory
DuckDB runs `catalog.py`'s real DDL. Nothing there is a mock that agrees with
itself — the SQL is the SQL the runner executes against DuckLake, and the
ciphertext is the ciphertext it PUTs to Garage.

Every KEK exercised is an ephemeral synthetic key generated in-process; every
fixture byte is obviously fake. No production key material is touched.
