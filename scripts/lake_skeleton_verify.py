"""Acceptance check for the phase-0 lake skeleton (DATA_LAKE_DESIGN.md §11.1).

Proves the two things the skeleton exists to prove, and refuses to pass on a
weaker signal than each claim deserves:

  1. the Garage bucket is reachable and round-trips objects byte-identically;
  2. the DuckLake catalog is queryable via DuckDB *and* its data actually lands
     as parquet in Garage — a successful SELECT alone would not distinguish a
     real S3 write from a local spill, so the object listing is asserted too.

Fixtures are deliberately absurd. Under §11.0 the skeleton runs before
encryption exists, so a sample row must be impossible to mistake for a real
record — in a screenshot, in a database, or in a stack trace.

Run it through the compose client profile: `scripts/lake-skeleton.sh verify`.
"""

import os
import sys

import duckdb

BUCKET = os.environ["LAKE_S3_BUCKET"]
ENDPOINT = os.environ["LAKE_S3_ENDPOINT"]
REGION = os.environ["LAKE_S3_REGION"]
DSN = os.environ["LAKE_CATALOG_DSN"]

# Obviously-synthetic fixtures (§11.0 guardrail): impossible dates, joke names,
# and values that name themselves as fake.
FIXTURES = [
    (1, "SYNTHETIC — Ada Notarealperson", "2999-01-01", "FAKE-RECORD-001", 11.11),
    (2, "SYNTHETIC — Bob Doesnotexist", "2999-02-02", "FAKE-RECORD-002", 22.22),
    (3, "SYNTHETIC — Carol Placeholder", "2999-03-03", "FAKE-RECORD-003", 33.33),
]

failures = []


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {label}" + (f" — {detail}" if detail else ""))
    if not condition:
        failures.append(label)


con = duckdb.connect()
for ext in ("httpfs", "postgres", "ducklake"):
    con.execute(f"LOAD {ext}")

# Path-style addressing and plain HTTP: Garage is on a private docker network
# with no TLS and no DNS-style bucket hostnames.
con.execute(
    f"""
    CREATE OR REPLACE SECRET garage (
        TYPE s3,
        KEY_ID '{os.environ["AWS_ACCESS_KEY_ID"]}',
        SECRET '{os.environ["AWS_SECRET_ACCESS_KEY"]}',
        ENDPOINT '{ENDPOINT}',
        REGION '{REGION}',
        URL_STYLE 'path',
        USE_SSL false
    )
    """
)

# --- 1. bucket round-trip -------------------------------------------------
probe = f"s3://{BUCKET}/_probe/round_trip.parquet"
con.execute(f"COPY (SELECT 42 AS answer, 'synthetic probe' AS note) TO '{probe}'")
row = con.execute(f"SELECT answer, note FROM read_parquet('{probe}')").fetchone()
check(
    "Garage bucket round-trips an object",
    row == (42, "synthetic probe"),
    f"read back {row!r} from {probe}",
)

# --- 2. DuckLake catalog is queryable ------------------------------------
# DATA_INLINING_ROW_LIMIT 0 is load-bearing, not tidiness. DuckLake inlines
# writes of up to 10 rows into the catalog database by default
# (ducklake.select/docs/stable/duckdb/advanced_features/data_inlining), so with
# stock settings a small insert never reaches the object store at all — it sits
# as rows in Postgres. That would make this script's S3 assertion vacuous, and
# in the real lake it would route data around the object-level encryption §9
# specifies. Writing straight to parquet keeps "data lives in the object store"
# true rather than usually-true.
con.execute(
    f"ATTACH 'ducklake:postgres:{DSN}' AS lake "
    f"(DATA_PATH 's3://{BUCKET}/bronze/', DATA_INLINING_ROW_LIMIT 0)"
)
con.execute("USE lake")
con.execute("DROP TABLE IF EXISTS synthetic_people")
con.execute(
    """
    CREATE TABLE synthetic_people (
        id INTEGER,
        full_name VARCHAR,
        fake_date DATE,
        record_ref VARCHAR,
        fake_amount DOUBLE
    )
    """
)
con.executemany("INSERT INTO synthetic_people VALUES (?, ?, ?, ?, ?)", FIXTURES)

rows = con.execute("SELECT id, full_name, record_ref FROM synthetic_people ORDER BY id").fetchall()
check(
    "DuckLake table is queryable through the Postgres catalog",
    len(rows) == len(FIXTURES),
    f"{len(rows)} row(s): {rows}",
)

check(
    "Fixtures are obviously synthetic",
    all(name.startswith("SYNTHETIC — ") for _, name, _ in rows),
    "every row's name is self-labelling",
)

# --- 3. the catalog's data really lives in Garage -------------------------
objects = [r[0] for r in con.execute(f"SELECT file FROM glob('s3://{BUCKET}/bronze/**')").fetchall()]
parquet = [o for o in objects if o.endswith(".parquet")]
check(
    "DuckLake wrote parquet into the Garage bucket",
    bool(parquet),
    f"{len(parquet)} parquet object(s), e.g. {parquet[0] if parquet else '—'}",
)

# The catalog itself must be in Postgres, not smuggled into a local file — this
# is what makes the lake "multiplayer" (§7) and what #2359/#2360 will attach to.
# Attached separately: `lake` is the DuckLake database, which does not expose the
# catalog's own tables.
con.execute(f"ATTACH '{DSN}' AS catalog_db (TYPE postgres, READ_ONLY)")
catalog_tables = con.execute(
    "SELECT count(*) FROM catalog_db.information_schema.tables "
    "WHERE table_name LIKE 'ducklake_%'"
).fetchone()[0]
check(
    "Catalog metadata lives in Postgres",
    catalog_tables > 0,
    f"{catalog_tables} ducklake_* table(s) in the catalog database",
)

# Belt-and-braces on the inlining setting above: if any row were inlined, the
# object store would not be the system of record for it.
inlined = con.execute(
    "SELECT count(*) FROM catalog_db.information_schema.tables "
    "WHERE table_name LIKE 'ducklake_inlined%'"
).fetchone()[0]
data_files = con.execute("SELECT count(*) FROM catalog_db.public.ducklake_data_file").fetchone()[0]
check(
    "Table data is in parquet files, not inlined into the catalog",
    data_files >= 1,
    f"{data_files} data-file row(s); {inlined} inlining table(s) present in schema",
)

# --- 4. snapshots exist (time-travel is the skeleton's stand-in for object
#        versioning, per §7) ------------------------------------------------
snapshots = con.execute("SELECT count(*) FROM lake.snapshots()").fetchone()[0]
check("DuckLake snapshots are recorded", snapshots > 0, f"{snapshots} snapshot(s)")

print()
if failures:
    print(f"FAILED: {len(failures)} check(s) — {', '.join(failures)}")
    sys.exit(1)
print("All checks passed — bucket reachable, catalog queryable, data in Garage.")
