# The staging promotion runner

Task #9758 (`#9546-A2`), child E2 of the explorer-upload epic #4121 (`#9546`,
child E). Implemented by `scripts/lake_promote_staging.py`; tested by
`tests/lake_promote_staging_unit.sh`.

DATA_LAKE_DESIGN.md §2 (bronze blobs + blob catalog), §8.6 (connector ledger),
§9 (layer 2 envelope encryption). Reads the catalog contract from
`scripts/lake/catalog.py` (#4270, `REAL_DATA_CATALOG.md`) and the object
crypto from `scripts/kek/` (#4133/#4134/#9546-A1, `KEK_CEREMONY.md`). It
re-derives neither, and `tests/lake_promote_staging_unit.sh` asserts that it
still does not.

**This document is the authoritative contract until #9547 (child C, the
uploader) lands.** #9547 is not yet built; this task's own design decision
(#9546 c59561 finding 2) was that the promoter writes the contract down first
and the uploader builds its `complete` step against it. If #9547's
implementation needs a field this document does not have, amend this document
in that task's PR rather than inventing an undocumented one.

## Why this is a second writer, not a flag on `lake_ingest.py`

A staged upload is not a real-data manifest: its digest is a *claim* made by a
network caller, not a declaration an operator typed into a local manifest
file, and it can be gigabytes, where `lake_ingest.py`'s one-shot in-memory
encrypt is bounded by what fits in RAM twice over. Both differences are
security-relevant (an untrusted claim must be re-verified; a large `high`
object must never require more memory than the box has), so this is its own
runner rather than a mode flag on the first one. It shares what must not
fork — the catalog contract and the envelope crypto — and owns what is
staging-specific: reading the claim back off storage, re-verifying it, and
cleaning up after itself.

## The staged-object layout

```
<staging bucket>/bronze/staging/<upload_id>/object         the assembled bytes, as uploaded
<staging bucket>/bronze/staging/<upload_id>/manifest.json   the claim about those bytes
```

`upload_id` is allocated by #9547's `init` endpoint and is otherwise opaque to
this runner — it only needs to be unique and to group one `object` with one
`manifest.json`. Both objects under an `upload_id` prefix are deleted together
once promotion succeeds; neither is ever read or written again after that.

## The manifest

```json
{
  "claimed_sha256": "3b2e...a91f",
  "bucket": "photos",
  "sensitivity": "high",
  "source_filename": "vacation.jpg",
  "mime": "image/jpeg",
  "size_bytes": 4812345,
  "upload_time": "2026-11-09T00:00:00Z"
}
```

| field | required | meaning |
|---|---|---|
| `claimed_sha256` | yes | What #9547's `complete` step computed over the assembled bytes. **Untrusted** — §2 below re-verifies it with an independent streamed read before anything is promoted. |
| `bucket` | yes | The intake bucket the operator uploaded into (one of the five #9547 defines: `photos`, `docs`, `finance`, `medical`, `general`). Recorded on the promoted row as `dataset_id = "explorer-upload:<bucket>"` (see "Dataset id" below). |
| `sensitivity` | yes | `high` / `normal`, per #9547's bucket→sensitivity map (`photos`/`finance`/`medical` → `high`, `docs`/`general` → `normal`). Passed through `catalog.resolve_sensitivity`, so a missing or malformed value still fails closed to `high` here, the same as a real-data manifest. |
| `source_filename` | yes | The name the operator gave the file. Recorded as `asset_inventory.source_path`. |
| `mime` | yes | The sniffed content type (#9547 validates this against `bucket`, not this runner). Also used to derive `asset_inventory.kind`. |
| `size_bytes` | yes | The claimed size. **Not trusted for the catalog row** — the row's `size_bytes` is the byte count actually observed on the streamed re-read (§2), the same "size is of the bytes actually handled" property `lake_ingest.py` keeps. Kept in the manifest as part of the upload's own record, and available for a future cross-check. |
| `upload_time` | yes | When #9547 finished assembling the upload. Not copied onto the catalog row (`ingested_at` is the *promotion* time, a separate event); kept for #9547's own audit trail. |

All seven fields are required; a manifest missing any of them is refused for
that upload only (§3) — the run does not abort over one bad manifest.

## The three properties worth knowing

### 1. The claimed digest is re-verified, not trusted

A GET of `.../object` is streamed through an incremental SHA-256 and compared
against `claimed_sha256` **before** any promotion step runs. A mismatch
refuses that upload — it is left staged, named in the failure list, and
nothing is written for it. This is the one property `lake_ingest.py` does not
need: a local manifest path is something the operator already trusted by
writing it down; an upload is a claim made over the network by whatever client
called #9547, worth exactly as much as the server-side check that confirms it.

`sensitivity=high` promotion re-verifies a *second* time, independently: the
streamed encrypt pass (§2 below) also hashes the plaintext it reads and
confirms it still matches `claimed_sha256` before the spooled ciphertext is
trusted enough to PUT. Two reads, two independent checks — not an
optimisation away from one, because the object sits in a bucket this runner's
own key can read and write, and nothing else guarantees the bytes did not
change between the first GET and the second.

### 2. `normal` is a server-side copy; `high` is a streamed `/scratch` spool

- **`normal`**: `copy_object` from the staging bucket straight to
  `bronze/blobs/sha256/<hash>`. The bytes never pass through this process —
  Garage copies them server-side.
- **`high`**: streamed through `encrypt_for_storage_stream` (#9546-A1 +
  `envelope_store.py`) into a temp file under a `/scratch`-backed spool
  directory (LUKS at rest, per `KEK_CEREMONY.md`), then that spool file is PUT
  to bronze in one request and deleted. Plaintext never touches an
  unencrypted disk and never sits fully in memory — the encryptor holds one
  chunk (8 MiB) at a time, the same bound #9546-A1 established for the
  in-memory writer it replaces.

A single `put_object` of the spooled ciphertext, not true S3 multipart: Garage
and S3 both allow a single PUT up to several GB, which covers #4121's own
5 GB upload ceiling. True multipart would only matter past that, which this
epic does not admit.

### 3. The catalog row is the commit marker; cleanup is separate

Per upload: promote (copy or encrypt-and-PUT), **then** write the
`asset_inventory` row, **then** delete the staged `object` and `manifest.json`.
A crash between any two steps is recoverable on the next run:

- between promote and the row: an orphan bronze object the next run's
  re-promote (same content address) overwrites harmlessly;
- between the row and the delete: a staged duplicate whose `claimed_sha256`
  is already in the catalog's skip set. The next run recognises this (it is
  the one case where a known digest is *not* simply skipped) and finishes the
  delete that the crashed run did not reach.

A `high` upload's fail-closed KEK refusal is checked in a pre-flight pass over
every staged manifest, before a single object GET — the same reasoning as
`lake_ingest.py`'s own pre-flight, and for the same cost asymmetry: finding
"no KEK" after promoting nine of ten staged uploads is a worse place to
discover it than before the first one.

## Dataset id: the sweep's own id vs. each row's provenance

A single promotion run can promote uploads from several intake buckets in one
pass — there is no one "dataset" a sweep belongs to the way a real-data load
belongs to the manifest that named it. So the two id fields are deliberately
different:

- **`ingest_runs.dataset_id`** (the sweep's own ledger row) is the constant
  `"explorer-staging"` — it names the promotion mechanism, not any one source.
- **`asset_inventory.dataset_id`** (each promoted row) is
  `"explorer-upload:<bucket>"`, e.g. `explorer-upload:photos` —
  per-object provenance, matching how the explorer's own `dataset_id` facet
  already reads (`app/routes.py::list_assets`, filtered per row, not per run).

This is a design decision made by this task in the absence of an upstream
spec for it (#9546 c59561 did not fix a dataset-id scheme), stated here so a
later reader does not mistake it for an oversight. Open to revision once
#9547 exists and a real upload is dogfooded end to end.

## Running it

```
scripts/lake-skeleton.sh promote              # promote
scripts/lake-skeleton.sh promote --dry-run     # report only
```

Directly, outside compose: `python scripts/lake_promote_staging.py [--dry-run]`,
with `LAKE_S3_*`, `LAKE_S3_STAGING_BUCKET`, `AWS_*`, `LAKE_CATALOG_DSN`,
`LAKE_SPOOL_DIR` (default `/scratch-spool`) and (for a staged `high` upload)
`LAKE_KEK_HEX` in the environment — the staging-bucket name and the spool
directory are the only additions over `lake_ingest.py`'s own variables.

The runner key (`lake-skeleton-rw` on the skeleton; the prod grant is noted on
#9601 per #9546 c59561 finding 3) needs read, write and delete on the staging
bucket and its existing read/write on bronze — no new provisioning beyond
what `lake-skeleton.sh`'s `bootstrap_garage` already grants it.

## What this subtask did NOT do

Promote a real upload. #9547 (the uploader) is not built, so nothing has ever
been staged by the real path — this is tested against synthetic staged
objects written directly to a test bucket. The first real promotion is gated
on #9547 landing and a real multi-part upload completing.

## Testing

`./tests/lake_promote_staging_unit.sh` — two suites, mirroring
`lake_ingest_unit.sh`.

The **host** suite needs no docker: it asserts the structural property the
round-trip cannot — that the runner imports the catalog contract and the
envelope gate rather than growing its own copy, that the compose mounts and
spool volume it depends on are present, that `lake-skeleton.sh` exposes
`promote`, and that this document exists.

The **container** suite (`python:3.11-slim` + `cryptography boto3 moto
duckdb`, versions pinned to `Dockerfile-LakeDuckDB`'s `LAKE_REQUIREMENTS`)
drives the runner end to end against `moto` S3 and a real in-memory DuckDB
running `catalog.py`'s real DDL: a `normal` promotion, a `high` promotion and
its round-trip through `decrypt_from_storage`, a claimed-digest mismatch, the
no-KEK refusal, an idempotent re-run that cleans up a leftover staged
duplicate, and a direct catalog read proving a staged-but-unpromoted object
has no row (so the explorer's catalog-only read path cannot serve it — proven
by reading the catalog, not by re-deriving the explorer's own logic).

Every KEK exercised is an ephemeral synthetic key generated in-process; every
fixture byte is obviously fake. No production key material is touched.
