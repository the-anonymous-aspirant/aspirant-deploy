"""The lake catalog schema and the sensitivity-intake contract for REAL records.

DATA_LAKE_DESIGN.md §2 (blob catalog), §8.6 (connector ledger), §9 (layer 2).
Task #4270 (#4238-A2), layer 0 of the phase-1 real-data epic #4238.

Why this module exists
----------------------
Until now the catalog schema lived inline in `scripts/lake_skeleton_fixtures.py`
— the throwaway synthetic-fixtures loader. That was fine while the only rows
were hand-authored fakes. Phase 1 adds a second writer (the real ingest runner,
#4271) and a second reader (the explorer's real-record views, #4272), and a
schema defined inside one of its two writers is not a contract, it is a
coincidence. So the DDL and the intake rules move here, and the fixtures loader
imports them like everybody else — which also means the synthetic seed exercises
the real contract on every run instead of drifting away from it.

This module is deliberately stdlib-only. It carries no crypto and no S3, so it
can be self-tested on a bare host python with no `cryptography` and no docker —
unlike scripts/kek/, which needs both. Keep it that way: the moment this file
imports dek_envelope, the cheap test surface is gone.

What the fields are for
-----------------------
The synthetic schema described a blob well enough to *render* it. A real record
additionally has to answer, years later and under EU jurisdiction, four
questions the fixtures never had to: where did this come from, may it still be
here, who decided it was sensitive, and which key can still open it.

  dataset_id         Which #4238-A1 intake record this row came from. The join
                     back to the operator's written decision to load it.
  sensitivity_source How the sensitivity was decided — see resolve_sensitivity.
                     A 'high' row is worth much less at audit time if nobody can
                     say whether a human declared it or a default guessed it.
  retention_class    Retention intent, per dataset. The 2026-07-18 standing
                     ruling is "keep everything forever"; a dataset may narrow
                     that in its A1 record, which is why this is a column and
                     not a constant.
  jurisdiction       Where the data is held to be governed. EU per the same
                     ruling.
  kek_version        Which KEK wraps this row's DEK. NULL for a normal-
                     sensitivity row, which has no DEK at all. This duplicates
                     a field inside the wrapped-DEK header on purpose: it makes
                     "which rows are encrypted under a key we no longer hold?"
                     a catalog query instead of a full object scan. Because it
                     is a duplicate it can drift, so #4273's verification
                     harness cross-checks it against the header rather than
                     trusting it.
"""

# --------------------------------------------------------------------------
# Sensitivity — the vocabulary and the intake rule.
# --------------------------------------------------------------------------

SENSITIVITY_HIGH = "high"
SENSITIVITY_NORMAL = "normal"
SENSITIVITIES = (SENSITIVITY_HIGH, SENSITIVITY_NORMAL)

# How the value in `sensitivity` came to be, recorded alongside it.
SOURCE_DECLARED = "declared"
SOURCE_DEFAULTED = "defaulted"
SOURCE_UNRECOGNISED = "defaulted:unrecognised"

# Defaults from the operator's 2026-07-18 standing ruling. A dataset overrides
# them in its #4238-A1 intake record; these are what applies when it does not.
RETENTION_KEEP_FOREVER = "keep-forever"
JURISDICTION_EU = "EU"


def resolve_sensitivity(declared):
    """Resolve a declared sensitivity to (sensitivity, sensitivity_source).

    **Fail closed.** Anything this function cannot confidently read as 'normal'
    resolves to 'high', which means the blob gets envelope-encrypted on PUT and
    the ingest refuses outright if no KEK is loaded (#4134's property, which
    #4271 inherits).

    That asymmetry is the whole point. Over-encrypting a normal blob costs a key
    unwrap on read. Under-encrypting a high blob writes the operator's personal
    data to disk in the clear, and no later fix un-writes it. So a missing
    declaration, an empty string, and a typo all land on 'high':

        resolve_sensitivity("high")    -> ("high",   "declared")
        resolve_sensitivity("Normal")  -> ("normal", "declared")
        resolve_sensitivity(None)      -> ("high",   "defaulted")
        resolve_sensitivity("norml")   -> ("high",   "defaulted:unrecognised:norml")

    A typo does not raise. A bulk load of a hundred thousand records must not
    halt on one malformed manifest line — but it must not quietly write that
    record in the clear either, and it must leave enough behind to find the line
    afterwards. Hence: encrypt it, and record exactly what was misread.
    """
    if declared is None:
        return SENSITIVITY_HIGH, SOURCE_DEFAULTED

    normalised = str(declared).strip().lower()
    if not normalised:
        return SENSITIVITY_HIGH, SOURCE_DEFAULTED
    if normalised in SENSITIVITIES:
        return normalised, SOURCE_DECLARED
    return SENSITIVITY_HIGH, f"{SOURCE_UNRECOGNISED}:{normalised}"


# --------------------------------------------------------------------------
# Table DDL — one definition, shared by every writer.
# --------------------------------------------------------------------------

# §2's blob catalog: one row per content-addressed bronze blob.
#
# `ingested_at` widened DATE -> TIMESTAMP for phase 1. A synthetic seed writes
# every row on one fake day and never needs to order within it; a real bulk load
# runs for hours, and "which records did the run that died at 14:20 get through?"
# is unanswerable at DATE resolution. Widening keeps every existing predicate
# working (date_part('year', ingested_at) still reads the year), so the
# explorer's current views are unaffected.
ASSET_INVENTORY_COLUMNS = """
    sha256 VARCHAR, object_key VARCHAR, source_path VARCHAR, mime VARCHAR,
    size_bytes BIGINT, kind VARCHAR, sensitivity VARCHAR,
    wrapped_dek VARCHAR, ingested_at TIMESTAMP, ingest_run_id VARCHAR,
    dataset_id VARCHAR, sensitivity_source VARCHAR,
    retention_class VARCHAR, jurisdiction VARCHAR, kek_version INTEGER
"""

# The order the tuples in ASSET_INVENTORY_COLUMNS must be built in. Written out
# rather than parsed from the DDL so that a column reorder is a visible diff on
# both, not a silent transposition of two same-typed VARCHARs.
ASSET_INVENTORY_FIELDS = (
    "sha256", "object_key", "source_path", "mime",
    "size_bytes", "kind", "sensitivity",
    "wrapped_dek", "ingested_at", "ingest_run_id",
    "dataset_id", "sensitivity_source",
    "retention_class", "jurisdiction", "kek_version",
)

# §8.6's connector ledger: one row per ingest run, the audit trail for "what did
# we load, from where, under which key, and did it finish?".
#
# `started_on` widened DATE -> TIMESTAMP for the same reason as `ingested_at`.
# The name is kept — the explorer's §8 Runs & health page reads it, and renaming
# a column across a repo boundary buys nothing here.
INGEST_RUNS_COLUMNS = """
    run_id VARCHAR, source VARCHAR, started_on TIMESTAMP, duration_seconds DOUBLE,
    files_seen BIGINT, bytes_ingested BIGINT, status VARCHAR,
    dataset_id VARCHAR, runner_version VARCHAR, kek_version INTEGER,
    objects_high BIGINT, objects_normal BIGINT
"""

INGEST_RUNS_FIELDS = (
    "run_id", "source", "started_on", "duration_seconds",
    "files_seen", "bytes_ingested", "status",
    "dataset_id", "runner_version", "kek_version",
    "objects_high", "objects_normal",
)

# A run that never reported an outcome is not a success. Kept as a vocabulary so
# the explorer and the verification harness agree on what "finished" means.
RUN_STATUS_SUCCESS = "success"
RUN_STATUS_FAILED = "failed"
RUN_STATUS_PARTIAL = "partial"
RUN_STATUSES = (RUN_STATUS_SUCCESS, RUN_STATUS_FAILED, RUN_STATUS_PARTIAL)


def asset_row(
    *,
    sha256,
    object_key,
    source_path,
    mime,
    size_bytes,
    kind,
    sensitivity,
    sensitivity_source,
    wrapped_dek,
    ingested_at,
    ingest_run_id,
    dataset_id,
    retention_class=RETENTION_KEEP_FOREVER,
    jurisdiction=JURISDICTION_EU,
    kek_version=None,
):
    """Build one asset_inventory tuple in ASSET_INVENTORY_FIELDS order.

    Keyword-only on purpose: fifteen positional columns, eight of them VARCHAR,
    is a transposition waiting to happen — and a swapped `sensitivity` and
    `sensitivity_source` would be a security bug that no type checker catches.

    Raises on the two combinations that are incoherent rather than merely odd:
    a high row with no wrapped DEK (it claims encryption it does not have), and
    a normal row carrying one (it claims a key it should never have needed).
    Both mean the caller's encrypt branch and its catalog branch disagree, which
    is exactly the bug #4273 exists to catch — better to fail at the write.
    """
    if sensitivity == SENSITIVITY_HIGH and not wrapped_dek:
        raise ValueError(
            f"refusing to catalog a sensitivity=high row with no wrapped DEK: {object_key}. "
            "The row would claim to be encrypted while the object is plaintext."
        )
    if sensitivity == SENSITIVITY_NORMAL and wrapped_dek:
        raise ValueError(
            f"refusing to catalog a sensitivity=normal row carrying a wrapped DEK: {object_key}. "
            "A normal blob is stored as-is and has no DEK; the caller's branches disagree."
        )
    if sensitivity == SENSITIVITY_HIGH and kek_version is None:
        raise ValueError(
            f"refusing to catalog a sensitivity=high row with no kek_version: {object_key}. "
            "A row whose wrapping key cannot be identified is not recoverable."
        )
    return (
        sha256, object_key, source_path, mime,
        size_bytes, kind, sensitivity,
        wrapped_dek, ingested_at, ingest_run_id,
        dataset_id, sensitivity_source,
        retention_class, jurisdiction, kek_version,
    )


def run_row(
    *,
    run_id,
    source,
    started_on,
    duration_seconds,
    files_seen,
    bytes_ingested,
    status,
    dataset_id,
    runner_version,
    kek_version=None,
    objects_high=0,
    objects_normal=0,
):
    """Build one ingest_runs tuple in INGEST_RUNS_FIELDS order."""
    if status not in RUN_STATUSES:
        raise ValueError(f"unknown ingest run status {status!r}; expected one of {RUN_STATUSES}")
    if objects_high and kek_version is None:
        raise ValueError(
            f"run {run_id} wrote {objects_high} high-sensitivity object(s) but records no "
            "kek_version; the run cannot say which key opens what it wrote."
        )
    return (
        run_id, source, started_on, duration_seconds,
        files_seen, bytes_ingested, status,
        dataset_id, runner_version, kek_version,
        objects_high, objects_normal,
    )


# --------------------------------------------------------------------------
# Self-test — stdlib only, runs anywhere. `python scripts/lake/catalog.py --self-test`
# --------------------------------------------------------------------------

def _self_test():
    checks = []

    def check(name, ok, detail=""):
        checks.append(ok)
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))

    # --- the intake rule ---------------------------------------------------
    check("declared high stays high",
          resolve_sensitivity("high") == (SENSITIVITY_HIGH, SOURCE_DECLARED))
    check("declared normal stays normal",
          resolve_sensitivity("normal") == (SENSITIVITY_NORMAL, SOURCE_DECLARED))
    check("case and whitespace are normalised",
          resolve_sensitivity("  HiGh  ") == (SENSITIVITY_HIGH, SOURCE_DECLARED))
    check("None fails closed to high",
          resolve_sensitivity(None) == (SENSITIVITY_HIGH, SOURCE_DEFAULTED))
    check("empty string fails closed to high",
          resolve_sensitivity("   ") == (SENSITIVITY_HIGH, SOURCE_DEFAULTED))

    typo, typo_source = resolve_sensitivity("norml")
    check("a typo fails closed to high rather than to normal", typo == SENSITIVITY_HIGH,
          f"got {typo}")
    check("a typo records what was misread", typo_source.endswith(":norml"), typo_source)

    # The property that actually matters, stated as a property: nothing outside
    # the vocabulary may ever resolve to normal.
    junk = [None, "", " ", "norml", "HIGH-ish", "0", "false", "public", "n/a", "unknown"]
    check("no unrecognised value resolves to normal",
          all(resolve_sensitivity(v)[0] == SENSITIVITY_HIGH for v in junk))

    # --- the DDL and field lists agree ------------------------------------
    def ddl_names(ddl):
        return tuple(c.strip().split()[0] for c in ddl.replace("\n", " ").split(",") if c.strip())

    check("asset_inventory DDL matches its field order",
          ddl_names(ASSET_INVENTORY_COLUMNS) == ASSET_INVENTORY_FIELDS,
          f"{ddl_names(ASSET_INVENTORY_COLUMNS)}")
    check("ingest_runs DDL matches its field order",
          ddl_names(INGEST_RUNS_COLUMNS) == INGEST_RUNS_FIELDS,
          f"{ddl_names(INGEST_RUNS_COLUMNS)}")

    # --- row builders ------------------------------------------------------
    base = dict(
        sha256="a" * 64, object_key="bronze/blobs/sha256/aa/aa/" + "a" * 64,
        source_path="/real/doc.pdf", mime="application/pdf", size_bytes=11,
        kind="document", ingested_at="2026-08-25 09:00:00", ingest_run_id="RUN-1",
        dataset_id="DS-1",
    )
    normal = asset_row(sensitivity="normal", sensitivity_source="declared",
                       wrapped_dek=None, **base)
    check("a normal row has the DDL's arity", len(normal) == len(ASSET_INVENTORY_FIELDS))
    check("a normal row defaults to the standing ruling",
          normal[ASSET_INVENTORY_FIELDS.index("retention_class")] == RETENTION_KEEP_FOREVER
          and normal[ASSET_INVENTORY_FIELDS.index("jurisdiction")] == JURISDICTION_EU)
    check("a normal row carries no kek_version",
          normal[ASSET_INVENTORY_FIELDS.index("kek_version")] is None)

    high = asset_row(sensitivity="high", sensitivity_source="declared",
                     wrapped_dek="d2Rlaw==", kek_version=1, **base)
    check("a high row keeps its wrapped DEK in the right column",
          high[ASSET_INVENTORY_FIELDS.index("wrapped_dek")] == "d2Rlaw==")

    def raises(fn):
        try:
            fn()
        except ValueError:
            return True
        return False

    check("high with no wrapped DEK is refused",
          raises(lambda: asset_row(sensitivity="high", sensitivity_source="declared",
                                   wrapped_dek=None, kek_version=1, **base)))
    check("normal carrying a wrapped DEK is refused",
          raises(lambda: asset_row(sensitivity="normal", sensitivity_source="declared",
                                   wrapped_dek="d2Rlaw==", **base)))
    check("high with no kek_version is refused",
          raises(lambda: asset_row(sensitivity="high", sensitivity_source="declared",
                                   wrapped_dek="d2Rlaw==", kek_version=None, **base)))

    run_base = dict(run_id="RUN-1", source="DS-1", started_on="2026-08-25 09:00:00",
                    duration_seconds=1.5, files_seen=2, bytes_ingested=22,
                    dataset_id="DS-1", runner_version="0.1.0")
    ok_run = run_row(status="success", kek_version=1, objects_high=1, objects_normal=1,
                     **run_base)
    check("a run row has the DDL's arity", len(ok_run) == len(INGEST_RUNS_FIELDS))
    check("an unknown run status is refused",
          raises(lambda: run_row(status="done", **run_base)))
    check("a run that wrote high objects without a kek_version is refused",
          raises(lambda: run_row(status="success", objects_high=3, **run_base)))
    check("a run with no high objects needs no kek_version",
          len(run_row(status="success", objects_normal=3, **run_base)) == len(INGEST_RUNS_FIELDS))

    print(f"\ncatalog: {sum(checks)}/{len(checks)} checks passed")
    return all(checks)


if __name__ == "__main__":
    import sys

    if "--self-test" in sys.argv:
        sys.exit(0 if _self_test() else 1)
    print(__doc__)
