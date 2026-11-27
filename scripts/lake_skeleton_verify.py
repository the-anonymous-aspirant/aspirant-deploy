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

import boto3
import duckdb

# The catalog contract (#4270) — imported so the sensitivity-source vocabulary
# below is the same object the loader writes, not a copy that drifts from it.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lake"))
import catalog  # noqa: E402
# The content checks, scoped to what each can answer on a lake that has moved
# past the phase-0 fixtures (#12521). The encrypted-object header comes from the
# envelope format itself (mounted at /work/kek), not a copy of its bytes.
import skeleton_content  # noqa: E402
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "kek"))
from dek_envelope import AOBJ_MAGIC  # noqa: E402

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

    # #12521: the fixture-shape checks look at the fixture rows only; content
    # addressing holds for every row, checked the way each row is stored; the
    # free-text guardrail runs only on a fixtures-only lake, and never prints a
    # value from a lake that holds real ones. See scripts/lake/skeleton_content.py.
    FIXTURE_ID = catalog.SYNTHETIC_DATASET_ID

    def report(result):
        label, status, detail = result
        if status == skeleton_content.SKIP:
            print(f"[SKIP] {label} — {detail}")
        else:
            check(label, status == skeleton_content.PASS, detail)

    report(skeleton_content.high_fixture_row(con, FIXTURE_ID))

    # Content addressing must be true, not decorative: a blob not stored at its
    # own content address would make provenance (§8.5) a lie.
    def read_blob(key, nbytes):
        extra = {"Range": f"bytes=0-{nbytes - 1}"} if nbytes else {}
        return s3.get_object(Bucket=BUCKET, Key=key, **extra)["Body"].read()

    report(skeleton_content.content_addressing(con, read_blob, AOBJ_MAGIC))

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
        # sensitivity_source (#4270): structural vocabulary, not prose. Taken
        # from the contract module so adding a source there cannot silently
        # start failing this guardrail.
        catalog.SOURCE_DECLARED, catalog.SOURCE_DEFAULTED,
    }
    report(skeleton_content.self_labelling(con, FIXTURE_ID, EXPECTED, MARKERS, ALLOWED_ENUMS))

    report(skeleton_content.fixture_dates(con, FIXTURE_ID))

    # --- the phase-1 catalog contract (#4270 / #4238-A2) --------------------
    #
    # The skeleton is synthetic, but the *schema* it writes is the one the real
    # ingest runner (#4271) and the explorer's real-record views (#4272) code
    # against. Checking it here means the contract is exercised by the seed on
    # every run rather than only by catalog.py's own unit self-test.
    inventory_cols = {c[0] for c in con.execute("DESCRIBE lake.main.asset_inventory").fetchall()}
    missing_cols = [c for c in catalog.ASSET_INVENTORY_FIELDS if c not in inventory_cols]
    check("asset_inventory carries the phase-1 provenance columns", not missing_cols,
          f"missing: {missing_cols}" if missing_cols else f"{len(catalog.ASSET_INVENTORY_FIELDS)} columns")

    run_cols = {c[0] for c in con.execute("DESCRIBE lake.main.ingest_runs").fetchall()}
    missing_run_cols = [c for c in catalog.INGEST_RUNS_FIELDS if c not in run_cols]
    check("ingest_runs carries the phase-1 audit columns", not missing_run_cols,
          f"missing: {missing_run_cols}" if missing_run_cols else f"{len(catalog.INGEST_RUNS_FIELDS)} columns")

    # The invariant that matters, asserted over the data rather than the DDL: a
    # row's sensitivity and its key material have to agree. A high row missing
    # either half claims an encryption it does not have; a normal row carrying
    # either half means the loader's branches disagreed. catalog.asset_row()
    # refuses both at write time — this proves the refusal actually held.
    incoherent = con.execute(
        """
        SELECT count(*) FROM asset_inventory
        WHERE (sensitivity = 'high'   AND (wrapped_dek IS NULL OR kek_version IS NULL))
           OR (sensitivity = 'normal' AND (wrapped_dek IS NOT NULL OR kek_version IS NOT NULL))
        """
    ).fetchone()[0]
    check("Every row's sensitivity agrees with its key material", incoherent == 0,
          f"{incoherent} row(s) whose sensitivity and wrapped DEK disagree")

    unsourced = con.execute(
        "SELECT count(*) FROM asset_inventory WHERE sensitivity_source IS NULL"
    ).fetchone()[0]
    check("Every row records how its sensitivity was decided", unsourced == 0,
          f"{unsourced} row(s) with no sensitivity_source")

# --- 4. the explorer's credentials are read-only, PROVEN by being denied -----
#
# The lake bridge (#2409-D2) is bounded only if the credentials are bounded.
# Every other statement of that guarantee is a claim: the acceptance criterion
# says "read-only key", the compose comment says it, and the explorer's own
# source asserts it. None of those attempt a write.
#
# This does. A denied write is evidence; an assertion is not. It matters
# specifically because both read-only credentials began life as HAND-MADE
# artifacts on one host — correct there, absent from this repo, and silently
# gone after the destroy-and-recreate that LAKE_SKELETON.md makes an acceptance
# criterion. The failure mode is not a wrong key handed over; it is the right
# key that no rebuild reproduces.
EXPLORER_KEY = os.environ.get("EXPLORER_S3_ACCESS_KEY", "")
EXPLORER_SECRET = os.environ.get("EXPLORER_S3_SECRET_KEY", "")

if not EXPLORER_KEY or not EXPLORER_SECRET:
    # Reported, not silently skipped. A quiet pass here would read as "the
    # bound holds" on exactly the hosts where it has not been established.
    check(
        "Explorer read-only S3 key is provisioned",
        False,
        "EXPLORER_S3_ACCESS_KEY/SECRET absent — run 'lake-skeleton.sh up' to issue them",
    )
else:
    ro = boto3.client(
        "s3",
        endpoint_url=f"http://{ENDPOINT}",
        aws_access_key_id=EXPLORER_KEY,
        aws_secret_access_key=EXPLORER_SECRET,
        region_name=REGION,
    )

    # It must still be able to READ, or "read-only" has become "no access" and
    # the explorer is broken in a way that looks like security working.
    try:
        ro.list_objects_v2(Bucket=BUCKET, MaxKeys=1)
        can_read = True
        read_detail = "list_objects_v2 succeeded"
    except Exception as exc:  # noqa: BLE001 — any failure is a failure to read
        can_read = False
        read_detail = f"{type(exc).__name__}: {exc}"
    check("Explorer key can READ the bronze bucket", can_read, read_detail)

    try:
        ro.put_object(Bucket=BUCKET, Key=".readonly-probe", Body=b"probe")
        denied = False
        write_detail = "PUT SUCCEEDED — the key is read-write, the bridge is not bounded"
        try:
            ro.delete_object(Bucket=BUCKET, Key=".readonly-probe")
        except Exception:  # noqa: BLE001 — cleanup is best-effort
            pass
    except Exception as exc:  # noqa: BLE001
        code = getattr(exc, "response", {}).get("Error", {}).get("Code", type(exc).__name__)
        denied = True
        write_detail = f"PUT denied ({code})"
    check("Explorer key CANNOT write to the bronze bucket", denied, write_detail)

# The catalog role gets the same treatment: SELECT must work, write must not.
RO_DSN = os.environ.get("LAKE_CATALOG_RO_DSN", "")
if not RO_DSN:
    check(
        "Explorer read-only catalog role is provisioned",
        False,
        "LAKE_CATALOG_RO_DSN absent — run 'lake-skeleton.sh up' to issue it",
    )
else:
    roc = duckdb.connect()
    roc.execute("LOAD postgres")
    try:
        roc.execute(f"ATTACH '{RO_DSN}' AS ro_cat (TYPE postgres)")
        roc.execute("SELECT 1 FROM ro_cat.information_schema.tables LIMIT 1").fetchone()
        cat_read = True
        cat_read_detail = "SELECT through the read-only role succeeded"
    except Exception as exc:  # noqa: BLE001
        cat_read = False
        cat_read_detail = f"{type(exc).__name__}: {exc}"
    check("Explorer catalog role can SELECT", cat_read, cat_read_detail)

    if cat_read:
        try:
            roc.execute("CREATE TABLE ro_cat.public.readonly_probe (x INTEGER)")
            cat_denied = False
            cat_detail = "CREATE TABLE SUCCEEDED — the role is not SELECT-only"
            try:
                roc.execute("DROP TABLE ro_cat.public.readonly_probe")
            except Exception:  # noqa: BLE001
                pass
        except Exception as exc:  # noqa: BLE001
            cat_denied = True
            cat_detail = f"CREATE TABLE denied ({type(exc).__name__})"
        check("Explorer catalog role CANNOT write", cat_denied, cat_detail)

# --- 7. the explorer's staging key is WRITE-ONLY, on staging only (#9601) ----
#
# The upload path's key (#4121-B). Same discipline as section 4: every bound is
# proven by an attempt, not asserted. It must be able to WRITE staging, by the
# multipart sequence the upload API uses, or the upload path is broken in a way
# that looks like security working. It must not READ staging, where sensitive
# uploads wait unwrapped until promotion, and it must not touch bronze at all.
STAGING_BUCKET = os.environ.get("LAKE_S3_STAGING_BUCKET", "")
STAGING_KEY = os.environ.get("EXPLORER_S3_STAGING_ACCESS_KEY", "")
STAGING_SECRET = os.environ.get("EXPLORER_S3_STAGING_SECRET_KEY", "")


def denied(fn):
    """(True, code) only when Garage REFUSES the call; (False, detail) otherwise.

    Only an access refusal counts. A NoSuchBucket, a timeout or a wrong
    endpoint is also an exception, and reading one of those as "the bound
    holds" would pass this check on a broken setup (security review, #9601
    c59052).
    """
    try:
        fn()
    except Exception as exc:  # noqa: BLE001 — classified below, not swallowed
        resp = getattr(exc, "response", None) or {}
        code = resp.get("Error", {}).get("Code", "")
        status = resp.get("ResponseMetadata", {}).get("HTTPStatusCode")
        if code in ("AccessDenied", "Forbidden", "403") or status == 403:
            return True, code or "HTTP 403"
        return False, f"not an access refusal: {type(exc).__name__}: {code or exc}"
    return False, "call SUCCEEDED"


if not STAGING_BUCKET or not STAGING_KEY or not STAGING_SECRET:
    check(
        "Explorer staging write key is provisioned",
        False,
        "LAKE_S3_STAGING_BUCKET / EXPLORER_S3_STAGING_* absent — run 'lake-skeleton.sh up'",
    )
else:
    wo = boto3.client(
        "s3",
        endpoint_url=f"http://{ENDPOINT}",
        aws_access_key_id=STAGING_KEY,
        aws_secret_access_key=STAGING_SECRET,
        region_name=REGION,
    )
    probe = ".staging-write-probe"
    try:
        up = wo.create_multipart_upload(Bucket=STAGING_BUCKET, Key=probe)["UploadId"]
        etag = wo.upload_part(
            Bucket=STAGING_BUCKET, Key=probe, UploadId=up, PartNumber=1, Body=b"probe"
        )["ETag"]
        wo.complete_multipart_upload(
            Bucket=STAGING_BUCKET,
            Key=probe,
            UploadId=up,
            MultipartUpload={"Parts": [{"ETag": etag, "PartNumber": 1}]},
        )
        wrote, write_detail = True, "create/upload_part/complete succeeded"
    except Exception as exc:  # noqa: BLE001
        wrote, write_detail = False, f"{type(exc).__name__}: {exc}"
    check("Explorer staging key can WRITE staging (multipart)", wrote, write_detail)

    ok, detail = denied(lambda: wo.get_object(Bucket=STAGING_BUCKET, Key=probe))
    check("Explorer staging key CANNOT read staging", ok, detail)
    ok, detail = denied(lambda: wo.list_objects_v2(Bucket=STAGING_BUCKET, MaxKeys=1))
    check("Explorer staging key CANNOT list staging", ok, detail)
    ok, detail = denied(lambda: wo.list_objects_v2(Bucket=BUCKET, MaxKeys=1))
    check("Explorer staging key CANNOT read bronze", ok, detail)
    ok, detail = denied(lambda: wo.put_object(Bucket=BUCKET, Key=".staging-key-probe", Body=b"x"))
    check("Explorer staging key CANNOT write bronze", ok, detail)

    # Write-only is not append-only, and this records which it is rather than
    # assuming (security review, #9601 c59052). If the staging key can delete
    # (or overwrite) an object it wrote, a compromised explorer-api could swap a
    # staged upload before promotion. Confidentiality still holds; integrity
    # then rests on the upload ledger's hashes and on promotion re-verifying
    # them (#4121-C/E). A measurement, not a pass/fail: either answer is a
    # fact the promotion step's reviewer has to start from.
    del_probe = ".staging-delete-probe"
    try:
        wo.put_object(Bucket=STAGING_BUCKET, Key=del_probe, Body=b"d")
        refused, del_detail = denied(lambda: wo.delete_object(Bucket=STAGING_BUCKET, Key=del_probe))
        print(
            "  [measured] Explorer staging key DeleteObject on staging: "
            + (f"DENIED ({del_detail})" if refused else f"ALLOWED ({del_detail})")
        )
    finally:
        try:
            s3.delete_object(Bucket=STAGING_BUCKET, Key=del_probe)
        except Exception:  # noqa: BLE001 — cleanup is best-effort
            pass

    # The runner promotes out of staging (#4121-E): it must read there. It is
    # also what cleans up the probe, which the write-only key cannot see.
    try:
        got = s3.get_object(Bucket=STAGING_BUCKET, Key=probe)["Body"].read()
        s3.delete_object(Bucket=STAGING_BUCKET, Key=probe)
        runner_ok, runner_detail = got == b"probe", f"read {len(got)} bytes, then deleted"
    except Exception as exc:  # noqa: BLE001
        runner_ok, runner_detail = False, f"{type(exc).__name__}: {exc}"
    check("Ingest runner key can read and delete staging", runner_ok, runner_detail)

    if EXPLORER_KEY and EXPLORER_SECRET:
        ok, detail = denied(lambda: ro.put_object(Bucket=STAGING_BUCKET, Key=".ro-probe", Body=b"x"))
        check("Explorer read-only key CANNOT write staging", ok, detail)

# --- 8. the staging lister's key and role are bounded (system_3 #11615) -----
#
# Security's conditions (c71659 on #11611, c71693 on #11615), each proven by an
# attempt: the key can list staging and is refused a write there and any read
# of bronze; the role is refused an insert into any other catalog table; the
# explorer's role can read both new tables; and the lister's role owns neither,
# so it cannot ALTER them or GRANT on them.
LISTER_KEY = os.environ.get("LAKE_S3_STAGING_LISTER_ACCESS_KEY", "")
LISTER_SECRET = os.environ.get("LAKE_S3_STAGING_LISTER_SECRET_KEY", "")
LISTER_DSN = os.environ.get("LAKE_CATALOG_STAGING_LISTER_DSN", "")
LISTER_TABLES = ("staged_uploads", "staged_uploads_read")

if not (STAGING_BUCKET and LISTER_KEY and LISTER_SECRET and LISTER_DSN):
    check(
        "Staging lister is provisioned",
        False,
        "LAKE_S3_STAGING_LISTER_* / LAKE_CATALOG_STAGING_LISTER_DSN absent — run 'lake-skeleton.sh up'",
    )
else:
    import boto3 as _boto3

    li = _boto3.client(
        "s3",
        endpoint_url=f"http://{os.environ['LAKE_S3_ENDPOINT']}",
        aws_access_key_id=LISTER_KEY,
        aws_secret_access_key=LISTER_SECRET,
        region_name=os.environ.get("LAKE_S3_REGION", "garage"),
    )
    try:
        li.list_objects_v2(Bucket=STAGING_BUCKET, Prefix="bronze/staging/", Delimiter="/", MaxKeys=1)
        listed, list_detail = True, "list_objects_v2 on staging succeeded"
    except Exception as exc:  # noqa: BLE001
        listed, list_detail = False, f"{type(exc).__name__}: {exc}"
    check("Staging lister key can LIST staging", listed, list_detail)
    ok, detail = denied(lambda: li.put_object(Bucket=STAGING_BUCKET, Key=".lister-probe", Body=b"x"))
    check("Staging lister key CANNOT write staging", ok, detail)
    ok, detail = denied(lambda: li.list_objects_v2(Bucket=BUCKET, MaxKeys=1))
    check("Staging lister key CANNOT read bronze (list)", ok, detail)
    ok, detail = denied(lambda: li.get_object(Bucket=BUCKET, Key="bronze/.lister-probe"))
    check("Staging lister key CANNOT read bronze (get)", ok, detail)

    lic = duckdb.connect()
    lic.execute("LOAD postgres")
    try:
        lic.execute(f"ATTACH '{LISTER_DSN}' AS li_cat (TYPE postgres)")
        lic.execute("SELECT count(*) FROM li_cat.public.staged_uploads").fetchone()
        li_ok, li_detail = True, "SELECT on staged_uploads succeeded"
    except Exception as exc:  # noqa: BLE001 - the DSN is never printed; the type is enough
        li_ok, li_detail = False, f"{type(exc).__name__}"
    check("Staging lister role can reach staged_uploads", li_ok, li_detail)

    if li_ok:
        # Another catalog table: any public table but the two of its own.
        # Listed through Postgres's pg_tables, which every role can read, and
        # not information_schema: that shows a role only the tables it holds
        # a privilege on, so on a correctly bounded catalog it listed none and
        # this check could never pass (system_3 #12113).
        others = [
            r[0] for r in lic.execute(
                "SELECT tablename FROM postgres_query('li_cat', "
                "'SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = ''public''')"
            ).fetchall()
            if r[0] not in LISTER_TABLES
        ]
        if not others:
            check("Staging lister role CANNOT insert into another catalog table", False, "no other table to probe")
        else:
            target = sorted(others)[0]
            try:
                # Inside a transaction that is always rolled back (security's
                # N1, c72556 on #11707): even a wrong grant cannot leave a row
                # in a real catalog table.
                lic.execute(
                    f'CALL postgres_execute(\'li_cat\', \'BEGIN; INSERT INTO public."{target}" DEFAULT VALUES; ROLLBACK;\')'
                )
                refused, ref_detail = False, f"INSERT into {target} SUCCEEDED"
            except Exception as exc:  # noqa: BLE001
                msg = str(exc).lower()
                refused = "permission denied" in msg
                ref_detail = f"{target}: " + ("permission denied" if refused else f"not a permission refusal ({type(exc).__name__})")
            check("Staging lister role CANNOT insert into another catalog table", refused, ref_detail)

    if RO_DSN:
        roc2 = duckdb.connect()
        roc2.execute("LOAD postgres")
        roc2.execute(f"ATTACH '{RO_DSN}' AS ro_cat2 (TYPE postgres)")
        for table in LISTER_TABLES:
            try:
                roc2.execute(f"SELECT count(*) FROM ro_cat2.public.{table}").fetchone()
                ok, detail = True, "SELECT succeeded"
            except Exception as exc:  # noqa: BLE001
                ok, detail = False, f"{type(exc).__name__}"
            check(f"Explorer catalog role can SELECT {table}", ok, detail)
        owners = dict(roc2.execute(
            "SELECT tablename, tableowner FROM ro_cat2.pg_catalog.pg_tables "
            "WHERE schemaname = 'public' AND tablename IN ('staged_uploads', 'staged_uploads_read')"
        ).fetchall())
        for table in LISTER_TABLES:
            owner = owners.get(table)
            check(
                f"Staging lister role does NOT own {table}",
                owner is not None and owner != "staging_lister",
                f"owner: {owner}" if owner else "table missing",
            )

# --- 9. the Gmail linker's role is bounded (system_3 #11557) -----------------
#
# Security's A6c (c75393 on #11557), as the role itself: INSERT ... ON CONFLICT
# DO NOTHING of an existing key succeeds without SELECT; SELECT, UPDATE and
# DELETE on the link table and an INSERT into any other catalog table are
# refused; the role owns nothing. The probes live with the job
# (lake_gmail_link.prove_bounds) so its own test runs the same ones against a
# real Postgres. And the explorer's role can read the table.
LINKER_DSN = os.environ.get("LAKE_CATALOG_GMAIL_LINKER_DSN", "")
if not LINKER_DSN or LINKER_DSN == "pending":
    check(
        "Gmail linker is provisioned",
        False,
        "LAKE_CATALOG_GMAIL_LINKER_DSN absent — run 'lake-skeleton.sh up'",
    )
else:
    import lake_gmail_link

    glc = duckdb.connect()
    glc.execute("LOAD postgres")
    try:
        glc.execute(f"ATTACH '{LINKER_DSN}' AS gl_cat (TYPE postgres)")
        attached, att_detail = True, "attached"
    except Exception as exc:  # noqa: BLE001 - the DSN is never printed
        attached, att_detail = False, type(exc).__name__
    check("Gmail linker role can connect", attached, att_detail)
    if attached:
        for label, ok, detail in lake_gmail_link.prove_bounds(glc, "gl_cat"):
            check(label, ok, detail)
    if RO_DSN:
        roc3 = duckdb.connect()
        roc3.execute("LOAD postgres")
        roc3.execute(f"ATTACH '{RO_DSN}' AS ro_cat3 (TYPE postgres)")
        try:
            roc3.execute("SELECT count(*) FROM ro_cat3.public.gmail_attachment_links").fetchone()
            ok, detail = True, "SELECT succeeded"
        except Exception as exc:  # noqa: BLE001
            ok, detail = False, type(exc).__name__
        check("Explorer catalog role can SELECT gmail_attachment_links", ok, detail)

print()
if failures:
    print(f"FAILED: {len(failures)} check(s) — {', '.join(failures)}")
    sys.exit(1)
print("All checks passed — bucket reachable, catalog queryable, data in Garage.")
