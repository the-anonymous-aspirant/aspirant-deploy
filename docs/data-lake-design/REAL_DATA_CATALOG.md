# The real-data catalog contract

Task #4270 (`#4238-A2`), layer 0 of the phase-1 real-data epic (system_3 #4238).
Implemented by `scripts/lake/catalog.py`; tested by `tests/lake_catalog_unit.sh`.

DATA_LAKE_DESIGN.md §2 (blob catalog), §8.6 (connector ledger), §9 (layer 2).
That document is substrate-resident, not a file in this repo — see
`aspirant-deploy-conventions-and-lake-design-source`.

## What changed and why

Before phase 1 the lake had one writer: `scripts/lake_skeleton_fixtures.py`, the
throwaway synthetic-fixtures loader, which declared the `asset_inventory` DDL
inline. That was sufficient while every row was a hand-authored fake.

Phase 1 adds a second writer — the real ingest runner (#4271) — and a second
reader — the explorer's real-record views (#4272, a different repo and a
different agent). A schema defined inside one of its own writers is not a
contract between them, so the DDL and the intake rules moved into
`scripts/lake/catalog.py`, which all of them import.

The fixtures loader was rewired through it rather than left alone. That is the
part worth defending: it means the synthetic seed exercises the real contract on
every `lake-skeleton.sh seed`, so the contract cannot rot while nobody is
loading real data. `tests/lake_catalog_unit.sh` asserts that no writer has
quietly gone back to spelling out its own DDL.

## The sensitivity-intake rule

`catalog.resolve_sensitivity(declared) -> (sensitivity, sensitivity_source)`

**It fails closed.** Anything not confidently readable as `normal` resolves to
`high`, which means the blob is envelope-encrypted before it reaches Garage and
the ingest refuses outright if no KEK is loaded (#4134's property, inherited by
#4271).

| declared | resolves to | source |
|---|---|---|
| `"high"`, `"  HiGh  "` | `high` | `declared` |
| `"normal"`, `"Normal"` | `normal` | `declared` |
| `None`, `""`, `"   "` | `high` | `defaulted` |
| `"norml"`, anything else | `high` | `defaulted:unrecognised:norml` |

The asymmetry is deliberate and is the whole design. Over-encrypting a normal
blob costs one key unwrap on read. Under-encrypting a high blob writes the
operator's personal data to disk in the clear, and no later fix un-writes it.

A malformed value does **not** raise. A bulk load of a hundred thousand records
must not halt on one bad manifest line — but it must not quietly write that line
in the clear either, and it must leave enough behind to find it afterwards.
Hence: encrypt it, and record exactly what was misread in `sensitivity_source`.

That column is the reason the rule is auditable rather than merely safe. A `high`
row is worth much less at audit time if nobody can say whether a human declared
it or a default guessed it.

## Columns phase 1 added

A synthetic row only had to describe a blob well enough to *render* it. A real
row has to answer, years later and under EU jurisdiction, four questions the
fixtures never faced.

### `asset_inventory`

| column | question it answers |
|---|---|
| `dataset_id` | Where did this come from? Joins back to the operator's written intake record (#4269). |
| `sensitivity_source` | Who decided it was sensitive — a human, or a default? |
| `retention_class` | May it still be here? |
| `jurisdiction` | Whose law governs it? |
| `kek_version` | Which key can still open it? |

`ingested_at` widened `DATE` → `TIMESTAMP`. A synthetic seed writes every row on
one fake day and never orders within it; a real bulk load runs for hours, and
"which records did the run that died at 14:20 get through?" is unanswerable at
DATE resolution. Every existing predicate keeps working —
`date_part('year', ingested_at)` still reads the year — so the explorer's
current views are unaffected.

### `ingest_runs` (§8.6's connector ledger)

Added `dataset_id`, `runner_version`, `kek_version`, `objects_high`,
`objects_normal`. `started_on` widened `DATE` → `TIMESTAMP` for the same reason.
The column **name** is kept: the explorer's §8 Runs & health page reads it, and
renaming across a repo boundary buys nothing.

## `kek_version` is a deliberate duplicate

It also lives inside the wrapped-DEK header
(`dek_envelope.wrapped_dek_kek_version`). Duplicating it in the catalog turns
*"which rows are encrypted under a key we no longer hold?"* — which is a data-loss
question, not a security one — into a catalog query instead of a full object scan.

Because it is a duplicate it can drift. So #4273's verification harness
cross-checks the column against the header rather than trusting it. Do not treat
the column as authoritative; the header is.

## Refusals at write time

`catalog.asset_row()` raises rather than writing three incoherent rows:

- `sensitivity=high` with no `wrapped_dek` — the row claims an encryption the
  object does not have.
- `sensitivity=normal` carrying a `wrapped_dek` — the caller's encrypt branch and
  its catalog branch disagree.
- `sensitivity=high` with no `kek_version` — a row whose wrapping key cannot be
  identified is not recoverable. That is data loss, not security.

`catalog.run_row()` refuses an unknown run status, and refuses a run that reports
high-sensitivity objects without naming the KEK that wrapped them.

These are the mismatches #4273's harness exists to detect after the fact.
Refusing them at the write is cheaper and leaves nothing to clean up.

## Defaults come from a ruling, not from taste

`RETENTION_KEEP_FOREVER = "keep-forever"` and `JURISDICTION_EU = "EU"` are the
operator's 2026-07-18 standing ruling. They are per-row **columns** rather than
constants precisely so a dataset can narrow them in its #4269 intake record —
"keep everything forever" is the default, not a property of the schema.

## Testing

`./tests/lake_catalog_unit.sh` — no docker, no `pip install`. `catalog.py` is
deliberately stdlib-only: it carries no crypto and no S3, unlike `scripts/kek/`,
which needs both. Keep it that way. The moment this module imports
`dek_envelope`, the rule you most want re-checkable on a bare host stops being
checkable there.
