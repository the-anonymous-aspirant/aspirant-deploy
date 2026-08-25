"""Execute the catalog contract's DDL against a real DuckDB. Task #4270 (#4238-A2).

tests/lake_catalog_unit.sh proves the *rules* in scripts/lake/catalog.py on a
bare host python. It cannot prove the DDL is valid SQL, because DuckDB is not
installed there — so a typo in a column type would pass every unit check and
only surface when someone seeds a skeleton inside the client container.

The check that most needs a real engine is the phase-1 widening of
`ingested_at` and `started_on` from DATE to TIMESTAMP. That widening is only
safe if every predicate already written against those columns keeps working;
`date_part('year', ingested_at) <> 2999` is the one the skeleton verifier runs
on every seed, and asserting it here is what makes the widening a claim with
evidence rather than a claim.

Run via tests/lake_catalog_ddl.sh (needs docker).
"""

import sys

import duckdb

sys.path.insert(0, "/repo/scripts/lake")
import catalog  # noqa: E402

FAILS = []


def check(name, ok, detail=""):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        FAILS.append(name)


con = duckdb.connect()
con.execute(f"CREATE TABLE asset_inventory ({catalog.ASSET_INVENTORY_COLUMNS})")
con.execute(f"CREATE TABLE ingest_runs ({catalog.INGEST_RUNS_COLUMNS})")
check("Both tables' DDL is valid SQL", True, "asset_inventory + ingest_runs created")

base = dict(source_path="/synthetic/x.pdf", mime="application/pdf", size_bytes=11,
            kind="document", ingest_run_id="FAKE-RUN-001", dataset_id="SYNTHETIC — FAKE-DATASET-000")
rows = [
    catalog.asset_row(sha256="a" * 64, object_key="bronze/blobs/sha256/aa/aa/" + "a" * 64,
                      sensitivity="normal", sensitivity_source=catalog.SOURCE_DECLARED,
                      wrapped_dek=None, ingested_at="2999-01-01 01:11:11", **base),
    catalog.asset_row(sha256="b" * 64, object_key="bronze/blobs/sha256/bb/bb/" + "b" * 64,
                      sensitivity="high", sensitivity_source=catalog.SOURCE_DEFAULTED,
                      wrapped_dek="d2Rlaw==", kek_version=1,
                      ingested_at="2999-01-01 22:11:11", **base),
]
placeholders = ", ".join("?" for _ in catalog.ASSET_INVENTORY_FIELDS)
con.executemany(f"INSERT INTO asset_inventory VALUES ({placeholders})", rows)
check("asset_row() tuples insert at the DDL's arity",
      con.execute("SELECT count(*) FROM asset_inventory").fetchone()[0] == 2)

runs = [catalog.run_row(run_id="FAKE-RUN-001", source="SYNTHETIC — fake-source-a",
                        started_on="2999-01-01 01:11:11", duration_seconds=11.11,
                        files_seen=2, bytes_ingested=33, status=catalog.RUN_STATUS_SUCCESS,
                        dataset_id="SYNTHETIC — FAKE-DATASET-000",
                        runner_version="FAKE-skeleton-0.0.0", kek_version=1,
                        objects_high=1, objects_normal=1)]
placeholders = ", ".join("?" for _ in catalog.INGEST_RUNS_FIELDS)
con.executemany(f"INSERT INTO ingest_runs VALUES ({placeholders})", runs)
check("run_row() tuples insert at the DDL's arity",
      con.execute("SELECT count(*) FROM ingest_runs").fetchone()[0] == 1)

# The widening's backward-compatibility claim, tested rather than asserted.
outside = con.execute(
    "SELECT count(*) FROM asset_inventory WHERE date_part('year', ingested_at) <> 2999"
).fetchone()[0]
check("date_part('year', ...) still reads a TIMESTAMP ingested_at", outside == 0,
      f"{outside} row(s) read as outside 2999")

# The reason for the widening: two rows written on the same fake day are now
# orderable, which they were not at DATE resolution.
after_noon = con.execute(
    "SELECT count(*) FROM asset_inventory WHERE ingested_at > TIMESTAMP '2999-01-01 12:00:00'"
).fetchone()[0]
check("Rows on the same day are orderable by time", after_noon == 1,
      f"{after_noon} row(s) after noon, expected 1")

# NULL kek_version has to survive the round trip as NULL, not as 0 — the
# verifier's coherence query keys on IS NULL.
null_kek = con.execute(
    "SELECT count(*) FROM asset_inventory WHERE sensitivity = 'normal' AND kek_version IS NULL"
).fetchone()[0]
check("A normal row's kek_version round-trips as NULL", null_kek == 1)

incoherent = con.execute(
    """
    SELECT count(*) FROM asset_inventory
    WHERE (sensitivity = 'high'   AND (wrapped_dek IS NULL OR kek_version IS NULL))
       OR (sensitivity = 'normal' AND (wrapped_dek IS NOT NULL OR kek_version IS NOT NULL))
    """
).fetchone()[0]
check("The verifier's coherence query runs and finds nothing", incoherent == 0)

print(f"\ncatalog DDL: {6 - len(FAILS)}/6 checks passed")
sys.exit(1 if FAILS else 0)
