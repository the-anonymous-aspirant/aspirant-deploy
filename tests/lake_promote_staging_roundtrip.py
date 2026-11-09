"""Drive the staging promotion runner end-to-end against moto S3 + real DuckDB.

Task #9758 (`#9546-A2`), child E2 of the explorer-upload epic #4121 (`#9546`).
DATA_LAKE_DESIGN.md §9 layer 2 success criterion, applied to promotion: a
`high` object read raw from bronze is NOT plaintext, and nothing is served
before it has a catalog row.

What this exercises
--------------------
`scripts/lake_promote_staging.py` end to end — listing staged uploads,
re-verifying the claimed digest, the normal/high promotion split, the
catalog row as commit marker, cleanup, and the fail-closed KEK pre-flight —
against a real DuckDB running the real DDL from `scripts/lake/catalog.py` and
`moto` standing in for Garage (both buckets live in the same moto S3).

Every KEK here is an ephemeral synthetic key generated in-process; every
fixture byte is obviously-fake. No production key material and no real data.

Run in the container test (tests/lake_promote_staging_unit.sh), which installs
`cryptography boto3 moto duckdb`.
"""

import hashlib
import json
import os
import sys
import tempfile

import boto3
import duckdb
from moto import mock_aws

_REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(_REPO, "scripts"))
sys.path.insert(0, os.path.join(_REPO, "scripts", "kek"))
sys.path.insert(0, os.path.join(_REPO, "scripts", "lake"))

import catalog  # noqa: E402
import lake_promote_staging as promote_mod  # noqa: E402
from envelope_store import decrypt_from_storage  # noqa: E402

# Each test gets its own bucket pair. moto's in-process S3 persists for the
# whole mock_aws context, so a shared bucket would let one test's leftovers
# falsify another's "nothing was promoted" assertion.
_BUCKET_PAIRS = iter(
    (f"lake-test-bronze-{n}", f"lake-test-staging-{n}") for n in range(1, 99)
)

PASSED = 0
FAILED = 0


def check(label, cond, detail=""):
    global PASSED, FAILED
    if cond:
        PASSED += 1
        print(f"[PASS] {label}")
    else:
        FAILED += 1
        print(f"[FAIL] {label}" + (f" — {detail}" if detail else ""))


# --------------------------------------------------------------------------
# Fixtures. Obviously-fake bytes, in the §11.0 house style.
# --------------------------------------------------------------------------

PHOTO = b"SYNTHETIC PHOTO BYTES - NOT REAL - FAKE-UPLOAD-9758-" + os.urandom(512)
INVOICE = b"SYNTHETIC INVOICE - NOT REAL. Billed to: SYNTHETIC - Ada Notarealperson"


def fresh_buckets():
    bronze, staging = next(_BUCKET_PAIRS)
    client = boto3.client("s3", region_name="us-east-1")
    client.create_bucket(Bucket=bronze)
    client.create_bucket(Bucket=staging)
    return client, bronze, staging


def fresh_store():
    """A store over a plain in-memory DuckDB, running catalog.py's real DDL."""
    return promote_mod.DuckDBCatalogStore(duckdb.connect())


def stage_upload(s3, staging_bucket, upload_id, payload, *, bucket="photos",
                  sensitivity="high", claimed_sha256=None):
    """Write a staged object + manifest, as #9547's `complete` step would.

    `claimed_sha256` defaults to the real digest; a test passes a wrong one to
    exercise the mismatch-refusal path.
    """
    s3.put_object(Bucket=staging_bucket, Key=promote_mod._object_key(upload_id), Body=payload)
    manifest = {
        "claimed_sha256": claimed_sha256 or hashlib.sha256(payload).hexdigest(),
        "bucket": bucket,
        "sensitivity": sensitivity,
        "source_filename": f"{upload_id}.bin",
        "mime": "application/octet-stream",
        "size_bytes": len(payload),
        "upload_time": "2026-11-09T00:00:00Z",
    }
    s3.put_object(
        Bucket=staging_bucket, Key=promote_mod._manifest_key(upload_id),
        Body=json.dumps(manifest).encode("utf-8"),
    )


def staged_keys(s3, staging_bucket):
    return sorted(
        obj["Key"] for obj in
        s3.list_objects_v2(Bucket=staging_bucket, Prefix=promote_mod.STAGING_PREFIX)
        .get("Contents", [])
    )


def bronze_keys(s3, bronze_bucket):
    return sorted(
        obj["Key"] for obj in
        s3.list_objects_v2(Bucket=bronze_bucket).get("Contents", [])
    )


def rows(store, table, order_by=None):
    suffix = f" ORDER BY {order_by}" if order_by else ""
    return store.con.execute(f"SELECT * FROM {table}{suffix}").fetchall()


def ledger_row(store, run_id):
    found = store.con.execute("SELECT * FROM ingest_runs WHERE run_id = ?", [run_id]).fetchall()
    return found[0] if found else None


def field(table, row, name):
    fields = (
        catalog.ASSET_INVENTORY_FIELDS if table == "asset_inventory" else catalog.INGEST_RUNS_FIELDS
    )
    return row[fields.index(name)]


# --------------------------------------------------------------------------
# 1. Normal promotes via server-side copy; high via the streamed spool.
# --------------------------------------------------------------------------


def test_normal_and_high_promotion(kek):
    s3, bronze, staging = fresh_buckets()
    store = fresh_store()

    with tempfile.TemporaryDirectory() as spool_dir:
        stage_upload(s3, staging, "upload-high", PHOTO, bucket="photos", sensitivity="high")
        stage_upload(s3, staging, "upload-normal", INVOICE, bucket="docs", sensitivity="normal")

        summary = promote_mod.promote(
            s3=s3, staging_bucket=staging, bucket=bronze, store=store,
            kek=kek, spool_dir=spool_dir,
        )

    check("run status is success", summary["status"] == catalog.RUN_STATUS_SUCCESS, summary["status"])
    check("one high, one normal promoted",
          (summary["written_high"], summary["written_normal"]) == (1, 1),
          f"{summary['written_high']}/{summary['written_normal']}")

    by_path = {field("asset_inventory", r, "source_path"): r for r in rows(store, "asset_inventory")}
    check("both uploads produced a row", len(by_path) == 2, str(sorted(by_path)))

    # --- the high upload ----------------------------------------------------
    high_row = by_path["upload-high.bin"]
    raw_high = s3.get_object(
        Bucket=bronze, Key=field("asset_inventory", high_row, "object_key")
    )["Body"].read()
    check("raw high object carries the AOBJ header", raw_high[:4] == b"AOBJ")
    check("raw high object does not contain the plaintext", PHOTO not in raw_high)
    check("high row carries a wrapped DEK", bool(field("asset_inventory", high_row, "wrapped_dek")))
    check("high row's size_bytes is the real plaintext size",
          field("asset_inventory", high_row, "size_bytes") == len(PHOTO))
    check("high row's provenance is the per-bucket dataset id",
          field("asset_inventory", high_row, "dataset_id") == "explorer-upload:photos")
    recovered = decrypt_from_storage(
        raw_high, field("asset_inventory", high_row, "wrapped_dek"), lambda _v: kek
    )
    check("the row's own wrapped DEK decrypts the stored object byte-identically",
          recovered == PHOTO)

    # --- the normal upload: a server-side copy, byte-identical -------------
    normal_row = by_path["upload-normal.bin"]
    raw_normal = s3.get_object(
        Bucket=bronze, Key=field("asset_inventory", normal_row, "object_key")
    )["Body"].read()
    check("raw normal object is stored as plaintext, byte-identical", raw_normal == INVOICE)
    check("normal row carries no wrapped DEK",
          field("asset_inventory", normal_row, "wrapped_dek") is None)
    check("normal row's provenance is the per-bucket dataset id",
          field("asset_inventory", normal_row, "dataset_id") == "explorer-upload:docs")

    # --- cleanup: both staged objects and manifests are gone ---------------
    check("nothing remains staged", staged_keys(s3, staging) == [], str(staged_keys(s3, staging)))

    # --- the ledger row: the SWEEP's own dataset id, not either upload's ---
    ledger = ledger_row(store, summary["run_id"])
    check("the run wrote exactly one ledger row",
          ledger is not None and len(rows(store, "ingest_runs")) == 1)
    if ledger:
        check("the ledger row uses the sweep's own dataset id",
              field("ingest_runs", ledger, "dataset_id") == "explorer-staging")
        check("the ledger row splits objects by sensitivity",
              (field("ingest_runs", ledger, "objects_high"),
               field("ingest_runs", ledger, "objects_normal")) == (1, 1))
        check("the ledger row names the runner version",
              field("ingest_runs", ledger, "runner_version") == promote_mod.RUNNER_VERSION)


# --------------------------------------------------------------------------
# 2. A claimed digest that does not match the staged bytes is refused.
# --------------------------------------------------------------------------


def test_hash_mismatch_is_refused_and_left_staged(kek):
    s3, bronze, staging = fresh_buckets()
    store = fresh_store()

    with tempfile.TemporaryDirectory() as spool_dir:
        # A manifest claiming a digest that does not match the uploaded bytes.
        stage_upload(
            s3, staging, "upload-tampered", PHOTO, bucket="photos", sensitivity="high",
            claimed_sha256="0" * 64,
        )
        # A good upload alongside it, so the run's tolerance is exercised too.
        stage_upload(s3, staging, "upload-good", INVOICE, bucket="docs", sensitivity="normal")

        summary = promote_mod.promote(
            s3=s3, staging_bucket=staging, bucket=bronze, store=store,
            kek=kek, spool_dir=spool_dir,
        )

    check("the run is partial, not success", summary["status"] == catalog.RUN_STATUS_PARTIAL,
          summary["status"])
    check("the good upload still promotes", summary["written_normal"] == 1, str(summary))
    check("the tampered upload is named in the failure list",
          [f["upload_id"] for f in summary["failed"]] == ["upload-tampered"], str(summary["failed"]))
    check("the tampered upload's object is still staged (left alone, not deleted)",
          promote_mod._object_key("upload-tampered") in staged_keys(s3, staging))
    check("nothing was catalogued for the tampered upload",
          len(rows(store, "asset_inventory")) == 1)


def test_unreadable_manifest_is_refused_without_aborting_the_run(kek):
    s3, bronze, staging = fresh_buckets()
    store = fresh_store()

    with tempfile.TemporaryDirectory() as spool_dir:
        # The object is staged, but its manifest is missing required fields
        # (mime, size_bytes, upload_time) — written directly so the test
        # exercises the real "missing key" path, not a value that happens to
        # be falsy.
        s3.put_object(Bucket=staging, Key=promote_mod._object_key("upload-incomplete"), Body=PHOTO)
        broken = {
            "claimed_sha256": hashlib.sha256(PHOTO).hexdigest(),
            "bucket": "photos", "sensitivity": "high", "source_filename": "x.bin",
        }
        s3.put_object(
            Bucket=staging, Key=promote_mod._manifest_key("upload-incomplete"),
            Body=json.dumps(broken).encode("utf-8"),
        )
        stage_upload(s3, staging, "upload-good", INVOICE, bucket="docs", sensitivity="normal")

        summary = promote_mod.promote(
            s3=s3, staging_bucket=staging, bucket=bronze, store=store,
            kek=kek, spool_dir=spool_dir,
        )

    check("the run is partial", summary["status"] == catalog.RUN_STATUS_PARTIAL, summary["status"])
    check("the incomplete manifest is named by its upload_id",
          [f["upload_id"] for f in summary["failed"]] == ["upload-incomplete"], str(summary["failed"]))
    check("the good upload still promotes despite the bad manifest", summary["written_normal"] == 1)


# --------------------------------------------------------------------------
# 3. Fail closed on a missing KEK — nothing written, and the refusal is legible.
# --------------------------------------------------------------------------


def test_refuses_high_without_kek():
    s3, bronze, staging = fresh_buckets()
    store = fresh_store()

    with tempfile.TemporaryDirectory() as spool_dir:
        # The normal upload comes first, same reasoning as lake_ingest.py's
        # own test: even it must not be written once the pre-flight refuses.
        stage_upload(s3, staging, "upload-normal", INVOICE, bucket="docs", sensitivity="normal")
        stage_upload(s3, staging, "upload-high", PHOTO, bucket="photos", sensitivity="high")

        refused = False
        try:
            promote_mod.promote(
                s3=s3, staging_bucket=staging, bucket=bronze, store=store,
                kek=None, spool_dir=spool_dir,
            )
        except promote_mod.MissingKekError:
            refused = True

    check("a run with a staged high upload is refused with no KEK", refused)
    check("nothing was written to the catalog", rows(store, "asset_inventory") == [])
    check("no object was PUT to bronze, including the normal one ahead of the high one",
          bronze_keys(s3, bronze) == [], str(bronze_keys(s3, bronze)))
    check("both uploads are still staged", len(staged_keys(s3, staging)) == 4,
          str(staged_keys(s3, staging)))  # 2 objects + 2 manifests

    ledger = rows(store, "ingest_runs")
    check("the refusal is in the ledger, not silence", len(ledger) == 1)
    if ledger:
        check("the refused run's status is 'failed'",
              field("ingest_runs", ledger[0], "status") == catalog.RUN_STATUS_FAILED)
        check("a run that wrote nothing high names no KEK",
              field("ingest_runs", ledger[0], "kek_version") is None)

    # Fail-closed is not fail-always: an all-normal staging area needs no key.
    s3, bronze, staging = fresh_buckets()
    store = fresh_store()
    with tempfile.TemporaryDirectory() as spool_dir:
        stage_upload(s3, staging, "upload-normal", INVOICE, bucket="docs", sensitivity="normal")
        summary = promote_mod.promote(
            s3=s3, staging_bucket=staging, bucket=bronze, store=store,
            kek=None, spool_dir=spool_dir,
        )
    check("an all-normal staging area promotes with no KEK",
          summary["status"] == catalog.RUN_STATUS_SUCCESS and summary["written_normal"] == 1,
          summary["status"])


# --------------------------------------------------------------------------
# 4. Idempotent re-run: skips on the catalog row, cleans up a leftover stage.
# --------------------------------------------------------------------------


def test_rerun_skips_and_cleans_up_a_leftover_staged_duplicate(kek):
    s3, bronze, staging = fresh_buckets()
    store = fresh_store()

    with tempfile.TemporaryDirectory() as spool_dir:
        stage_upload(s3, staging, "upload-1", PHOTO, bucket="photos", sensitivity="high")

        first = promote_mod.promote(
            s3=s3, staging_bucket=staging, bucket=bronze, store=store,
            kek=kek, spool_dir=spool_dir,
        )
        check("run 1 promotes the upload", first["written_high"] == 1, str(first))
        check("run 1 leaves nothing staged", staged_keys(s3, staging) == [])

        after_first_bronze = bronze_keys(s3, bronze)
        assets_after_first = rows(store, "asset_inventory", order_by="sha256")

        # Simulate the crash-between-row-and-delete case: the row exists (from
        # run 1) but a staged duplicate re-appears — the same bytes, restaged
        # under a NEW upload_id, as a retried client upload would produce.
        stage_upload(s3, staging, "upload-1-retry", PHOTO, bucket="photos", sensitivity="high")

        puts = []
        real_put = s3.put_object

        def counting_put(**kwargs):
            puts.append(kwargs["Key"])
            return real_put(**kwargs)

        s3.put_object = counting_put
        try:
            second = promote_mod.promote(
                s3=s3, staging_bucket=staging, bucket=bronze, store=store,
                kek=kek, spool_dir=spool_dir,
            )
        finally:
            s3.put_object = real_put

        check("run 2 issues no PUT to bronze for an already-catalogued digest",
              puts == [], str(puts))
        check("run 2 reports the duplicate as skipped, not promoted",
              (second["skipped"], second["written_high"]) == (1, 0), str(second))
        check("run 2 cleans up the leftover staged duplicate",
              staged_keys(s3, staging) == [], str(staged_keys(s3, staging)))
        check("run 2 writes no new asset rows",
              rows(store, "asset_inventory", order_by="sha256") == assets_after_first)
        check("bronze is unchanged", bronze_keys(s3, bronze) == after_first_bronze)
        check("run 2 is still success — a cleaned-up duplicate is not a failure",
              second["status"] == catalog.RUN_STATUS_SUCCESS, second["status"])


# --------------------------------------------------------------------------
# 5. A staged-but-unpromoted object has no catalog row — cannot be served.
# --------------------------------------------------------------------------


def test_staged_object_has_no_catalog_row_before_promotion():
    s3, bronze, staging = fresh_buckets()
    store = fresh_store()
    store.ensure_tables()

    stage_upload(s3, staging, "upload-untouched", PHOTO, bucket="photos", sensitivity="high")

    check("a staged object has no asset_inventory row",
          store.con.execute(
              "SELECT count(*) FROM asset_inventory WHERE sha256 = ?",
              [hashlib.sha256(PHOTO).hexdigest()],
          ).fetchone()[0] == 0)
    # The explorer's read path resolves exclusively through a catalog lookup
    # (`_asset(sha256)`, aspirant-explorer app/routes.py, read per #9546
    # c59562) — a staged object with no row is unreachable through that path.
    # This asserts the catalog side of that property directly, which is what
    # makes a staged object unservable without re-deriving the explorer's own
    # lookup logic here.


# --------------------------------------------------------------------------
# 6. Manifest / listing mechanics.
# --------------------------------------------------------------------------


def test_listing_and_manifest_validation():
    s3, _bronze, staging = fresh_buckets()

    check("an empty staging area lists no uploads",
          promote_mod.list_staged_uploads(s3, staging) == [])

    stage_upload(s3, staging, "b-upload", INVOICE, bucket="docs", sensitivity="normal")
    stage_upload(s3, staging, "a-upload", PHOTO, bucket="photos", sensitivity="high")
    check("listing finds both uploads, sorted",
          promote_mod.list_staged_uploads(s3, staging) == ["a-upload", "b-upload"])

    manifest = promote_mod.read_manifest(s3, staging, "a-upload")
    check("the manifest round-trips every required field",
          all(f in manifest for f in promote_mod.REQUIRED_MANIFEST_FIELDS), str(manifest))

    try:
        promote_mod.read_manifest(s3, staging, "does-not-exist")
        check("reading a missing manifest raises ManifestError", False)
    except promote_mod.ManifestError:
        check("reading a missing manifest raises ManifestError", True)

    s3.put_object(Bucket=staging, Key=promote_mod._manifest_key("bad-json"), Body=b"{not json")
    try:
        promote_mod.read_manifest(s3, staging, "bad-json")
        check("malformed JSON raises ManifestError", False)
    except promote_mod.ManifestError:
        check("malformed JSON raises ManifestError", True)

    matched, size = promote_mod.verify_staged_object(
        s3, staging, "a-upload", hashlib.sha256(PHOTO).hexdigest()
    )
    check("verify confirms a correct claimed digest", matched)
    check("verify reports the real observed size", size == len(PHOTO))

    matched, _ = promote_mod.verify_staged_object(s3, staging, "a-upload", "f" * 64)
    check("verify refuses a wrong claimed digest", not matched)


# --------------------------------------------------------------------------


@mock_aws
def main():
    kek = os.urandom(32)  # ephemeral, synthetic, never persisted

    print("normal + high promotion:")
    test_normal_and_high_promotion(kek)
    print("\nhash mismatch is refused, leaves the upload staged:")
    test_hash_mismatch_is_refused_and_left_staged(kek)
    print("\nan unreadable manifest does not abort the run:")
    test_unreadable_manifest_is_refused_without_aborting_the_run(kek)
    print("\nfail-closed KEK refusal:")
    test_refuses_high_without_kek()
    print("\nre-run skips and cleans up a leftover staged duplicate:")
    test_rerun_skips_and_cleans_up_a_leftover_staged_duplicate(kek)
    print("\na staged object has no catalog row before promotion:")
    test_staged_object_has_no_catalog_row_before_promotion()
    print("\nlisting + manifest validation:")
    test_listing_and_manifest_validation()

    print()
    if FAILED:
        print(f"FAILED: {FAILED} failed, {PASSED} passed")
        return 1
    print(f"{PASSED} passed, 0 failed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
