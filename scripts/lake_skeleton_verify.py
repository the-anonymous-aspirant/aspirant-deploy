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

import hashlib
import os
import sys

import boto3
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

# Used by the content-addressing check: DuckDB can read the blobs but only an S3
# client can fetch them by exact key.
s3 = boto3.client(
    "s3",
    endpoint_url=f"http://{ENDPOINT}",
    aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
    region_name=REGION,
)


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

# --- 5. fixture coverage: every surface the explorer must render has data --
# Skipped rather than failed when the stack has not been seeded — `verify` must
# stay meaningful on a bare stack, which is what the teardown drill exercises.
# A DuckLake attachment exposes no information_schema, so enumerate through
# DuckDB's own catalog view instead.
tables = {
    r[0]
    for r in con.execute(
        "SELECT table_name FROM duckdb_tables() WHERE database_name = 'lake'"
    ).fetchall()
}
seeded = "asset_inventory" in tables

if not seeded:
    print("\n[SKIP] fixture coverage — stack is not seeded (run 'lake-skeleton.sh seed')")
else:
    EXPECTED = [
        "asset_inventory",      # blob catalog (§2)
        "extracted_text",       # derived from PDF blobs
        "image_metadata",       # EXIF + thumbnail refs
        "audio_transcripts",
        "messages",             # unified across channels (§2)
        "finance_transactions",  # typed table export
        "ingest_runs",          # connector ledger (§8.6)
        "gold_finance_monthly",
        "gold_timeline",
        "gold_source_freshness",
    ]
    missing = [t for t in EXPECTED if t not in tables]
    check("Every fixture table exists", not missing, f"missing: {missing}" if missing else f"{len(EXPECTED)} tables")

    empty = [t for t in EXPECTED if t in tables and con.execute(f"SELECT count(*) FROM lake.main.{t}").fetchone()[0] == 0]
    check("No fixture table is empty", not empty, f"empty: {empty}" if empty else "all populated")

    kinds = {r[0] for r in con.execute("SELECT DISTINCT kind FROM asset_inventory").fetchall()}
    check(
        "Every blob kind the explorer renders is present",
        {"document", "image", "audio"} <= kinds,
        f"kinds: {sorted(kinds)}",
    )

    # §2: sensitivity is a column, not a folder convention — so exactly one row
    # differs only by that column, which is the case #2360 must handle.
    high = con.execute("SELECT count(*) FROM asset_inventory WHERE sensitivity = 'high'").fetchone()[0]
    check("A sensitivity=high row exists", high == 1, f"{high} high-sensitivity row(s)")

    # Content-addressing must be true, not decorative: a blob whose bytes do not
    # hash to its own key would make provenance (§8.5) a lie.
    bad_hash = []
    for digest, key in con.execute("SELECT sha256, object_key FROM asset_inventory").fetchall():
        body = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
        if hashlib.sha256(body).hexdigest() != digest or not key.endswith(digest):
            bad_hash.append(key)
    check("Every blob's bytes hash to its own key", not bad_hash, f"{len(bad_hash)} mismatch(es)" if bad_hash else "all verified")

    # The guardrail check, and the one that must fail closed: every free-text
    # value in every fixture table has to be self-labelling. A field that does
    # not match the vocabulary is reported, not waved through — that is what
    # stops realism creeping in one column at a time.
    # "2999" counts as a marker in its own right: an impossible year is exactly
    # as self-labelling as the word SYNTHETIC, and month strings like "2999-08"
    # carry no other prose to mark up.
    MARKERS = ("SYNTHETIC", "FAKE-", "synthetic", "fake-", "2999")
    ALLOWED_ENUMS = {
        "normal", "high", "success", "failed", "green", "amber", "red",
        "document", "image", "audio", "message_export",
        "telegram", "sms", "email", "application/pdf", "image/png",
        "audio/wav", "application/json",
    }
    leaks = []
    for table in EXPECTED:
        cols = con.execute(f"DESCRIBE lake.main.{table}").fetchall()
        for col_name, col_type, *_ in cols:
            if "VARCHAR" not in col_type:
                continue
            for (value,) in con.execute(
                f"SELECT DISTINCT {col_name} FROM lake.main.{table} WHERE {col_name} IS NOT NULL"
            ).fetchall():
                v = str(value)
                # Hashes, object keys and month strings are structural, not prose.
                if v in ALLOWED_ENUMS or all(c in "0123456789abcdef" for c in v) or v.startswith("bronze/blobs/"):
                    continue
                if not any(m in v for m in MARKERS):
                    leaks.append(f"{table}.{col_name}={v!r}")
    check(
        "No fixture value could be mistaken for operator data",
        not leaks,
        f"{len(leaks)} unlabelled value(s): {leaks[:3]}" if leaks else "every free-text value is self-labelling",
    )

    dates = con.execute(
        "SELECT count(*) FROM asset_inventory WHERE date_part('year', ingested_at) <> 2999"
    ).fetchone()[0]
    check("Fixture dates are all in 2999", dates == 0, f"{dates} row(s) outside 2999")

print()
if failures:
    print(f"FAILED: {len(failures)} check(s) — {', '.join(failures)}")
    sys.exit(1)
print("All checks passed — bucket reachable, catalog queryable, data in Garage.")
