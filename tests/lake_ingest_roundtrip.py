"""Drive the real ingest runner end-to-end against moto S3 + real DuckDB.

Task #4271 (`#4238-B1`). DATA_LAKE_DESIGN.md §9 layer 2 success criterion: "read
the raw Garage object; it is NOT plaintext".

What this exercises that the #4134 round-trip did not
-----------------------------------------------------
`tests/envelope_ingest_s3_roundtrip.py` proved the *gate*
(`storage_body_and_wrapped_dek` + one `put_object`). This drives
`scripts/lake_ingest.py` itself — manifest parsing, the fail-closed pre-flight,
the PUT/row ordering, the skip set, the ledger row — against a real DuckDB
running the real DDL from `scripts/lake/catalog.py`. Nothing here is a mock that
agrees with itself: the SQL is the SQL the runner will execute against DuckLake,
and the ciphertext is the ciphertext it will PUT to Garage.

`moto` stands in for Garage so this needs no compose stack. The live Garage hop
is #4238-D1's joint acceptance with the explorer read half (#4272).

Every KEK here is an ephemeral synthetic key generated in-process; the fixture
bytes are obviously-fake. No production key material and no real data.

Run in the container test (tests/lake_ingest_unit.sh), which installs
`cryptography boto3 moto duckdb`.
"""

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
import lake_ingest  # noqa: E402
from envelope_store import decrypt_from_storage  # noqa: E402

# Each test gets its own bucket. `moto`'s in-process S3 persists for the whole
# `mock_aws` context, so a shared bucket would let one test's leftovers falsify
# another's "nothing was PUT" assertion — the assertion most worth trusting here.
_BUCKETS = iter(f"lake-test-bronze-{n}" for n in range(1, 99))

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
# Fixtures. Obviously-fake bytes, in the §11.0 house style — nothing this test
# writes should ever raise the question "wait, is that real?".
# --------------------------------------------------------------------------

NOTE = b"SYNTHETIC MEDICAL NOTE - NOT REAL. Patient: SYNTHETIC - Bob Doesnotexist"
INVOICE = b"SYNTHETIC INVOICE - NOT REAL. Billed to: SYNTHETIC - Ada Notarealperson"
PHOTO = b"SYNTHETIC PHOTO BYTES - NOT REAL - FAKE-IMAGE-001"
TYPO = b"SYNTHETIC TYPO-SENSITIVITY RECORD - NOT REAL - FAKE-DOC-002"


class _Undeclared:
    """Sentinel: this record omits `sensitivity` entirely (vs. declaring null)."""


UNDECLARED = _Undeclared()


def write_manifest(root, records, dataset_id="SYNTHETIC — FAKE-DATASET-4271"):
    """Materialise the record files and the manifest that names them.

    A record whose payload is None is named in the manifest and deliberately
    never written to disk — that is the unreadable-record case.
    """
    entries = []
    for name, payload, declared in records:
        if payload is not None:
            with open(os.path.join(root, name), "wb") as handle:
                handle.write(payload)
        entry = {"path": name}
        if declared is not UNDECLARED:
            entry["sensitivity"] = declared
        entries.append(entry)

    manifest_path = os.path.join(root, "manifest.json")
    with open(manifest_path, "w", encoding="utf-8") as handle:
        json.dump(
            {
                "dataset_id": dataset_id,
                "source": "SYNTHETIC — fake-source-4271",
                "records": entries,
            },
            handle,
        )
    return manifest_path


def fresh_store():
    """A store over a plain in-memory DuckDB, running catalog.py's real DDL."""
    return lake_ingest.DuckDBCatalogStore(duckdb.connect())


def fresh_bucket():
    """A moto S3 client plus a bucket no other test in this run touches."""
    bucket = next(_BUCKETS)
    client = boto3.client("s3", region_name="us-east-1")
    client.create_bucket(Bucket=bucket)
    return client, bucket


def rows(store, table, order_by=None):
    # Explicit ORDER BY where order matters: DuckDB does not promise insertion
    # order from a bare SELECT *, and a test reading rows positionally without
    # one is asserting on an accident.
    suffix = f" ORDER BY {order_by}" if order_by else ""
    return store.con.execute(f"SELECT * FROM {table}{suffix}").fetchall()


def ledger_row(store, run_id):
    """The one ingest_runs row a given run wrote, addressed by its run_id."""
    found = store.con.execute("SELECT * FROM ingest_runs WHERE run_id = ?", [run_id]).fetchall()
    return found[0] if found else None


def field(table, row, name):
    fields = (
        catalog.ASSET_INVENTORY_FIELDS if table == "asset_inventory" else catalog.INGEST_RUNS_FIELDS
    )
    return row[fields.index(name)]


def stored(s3, bucket):
    """Every object currently in the bucket, as {key: raw bytes}."""
    return {
        obj["Key"]: s3.get_object(Bucket=bucket, Key=obj["Key"])["Body"].read()
        for obj in s3.list_objects_v2(Bucket=bucket).get("Contents", [])
    }


# --------------------------------------------------------------------------
# 1-3, 7. Sensitivity resolution, encrypt-on-PUT, and the read-back round trip.
# --------------------------------------------------------------------------


def test_sensitivity_and_encryption(kek):
    s3, bucket = fresh_bucket()
    store = fresh_store()

    with tempfile.TemporaryDirectory() as root:
        manifest_path = write_manifest(
            root,
            [
                ("note.txt", NOTE, "high"),
                ("invoice.txt", INVOICE, "normal"),
                ("photo.bin", PHOTO, UNDECLARED),
                ("typo.txt", TYPO, "norml"),
            ],
        )
        summary = lake_ingest.ingest(
            lake_ingest.load_manifest(manifest_path),
            s3=s3, bucket=bucket, store=store, kek=kek,
        )

    check("run status is success", summary["status"] == catalog.RUN_STATUS_SUCCESS,
          summary["status"])
    check("three records fail closed to high, one is normal",
          (summary["written_high"], summary["written_normal"]) == (3, 1),
          f"{summary['written_high']}/{summary['written_normal']}")

    by_path = {field("asset_inventory", r, "source_path"): r
               for r in rows(store, "asset_inventory")}
    check("every manifest record produced a row", len(by_path) == 4, str(sorted(by_path)))

    # --- the declared-high record ------------------------------------------
    high_row = by_path["note.txt"]
    raw_high = s3.get_object(
        Bucket=bucket, Key=field("asset_inventory", high_row, "object_key")
    )["Body"].read()
    check("raw high object carries the AOBJ header", raw_high[:4] == b"AOBJ")
    check("raw high object does not contain the plaintext", NOTE not in raw_high)
    check("high row carries a wrapped DEK", bool(field("asset_inventory", high_row, "wrapped_dek")))
    check("high row names the KEK that wraps it",
          field("asset_inventory", high_row, "kek_version") == 1)
    check("high row's sensitivity_source records a human declaration",
          field("asset_inventory", high_row, "sensitivity_source") == catalog.SOURCE_DECLARED)
    check("size_bytes is of the PLAINTEXT, not the ciphertext",
          field("asset_inventory", high_row, "size_bytes") == len(NOTE),
          f"{field('asset_inventory', high_row, 'size_bytes')} vs {len(NOTE)}")
    check("the object key is the content address of the PLAINTEXT",
          field("asset_inventory", high_row, "object_key").endswith(
              field("asset_inventory", high_row, "sha256")))

    recovered = decrypt_from_storage(
        raw_high, field("asset_inventory", high_row, "wrapped_dek"), lambda _v: kek
    )
    check("the row's own wrapped DEK decrypts the stored object byte-identically",
          recovered == NOTE)

    # --- the declared-normal record ----------------------------------------
    normal_row = by_path["invoice.txt"]
    raw_normal = s3.get_object(
        Bucket=bucket, Key=field("asset_inventory", normal_row, "object_key")
    )["Body"].read()
    check("raw normal object is stored as plaintext", raw_normal == INVOICE)
    check("normal row carries no wrapped DEK",
          field("asset_inventory", normal_row, "wrapped_dek") is None)
    check("normal row carries no kek_version",
          field("asset_inventory", normal_row, "kek_version") is None)

    # --- fail closed on an omitted and on a misspelled declaration ---------
    undeclared_row = by_path["photo.bin"]
    check("an undeclared record is encrypted",
          s3.get_object(Bucket=bucket,
                        Key=field("asset_inventory", undeclared_row, "object_key")
                        )["Body"].read()[:4] == b"AOBJ")
    check("an undeclared record is marked defaulted, not declared",
          field("asset_inventory", undeclared_row, "sensitivity_source")
          == catalog.SOURCE_DEFAULTED)

    typo_row = by_path["typo.txt"]
    check("a misspelled sensitivity is encrypted rather than trusted",
          field("asset_inventory", typo_row, "sensitivity") == catalog.SENSITIVITY_HIGH)
    check("a misspelled sensitivity records what was misread",
          str(field("asset_inventory", typo_row, "sensitivity_source")).endswith(":norml"),
          str(field("asset_inventory", typo_row, "sensitivity_source")))

    # --- the provenance columns a real load has to answer for --------------
    check("rows carry the operator's retention default",
          all(field("asset_inventory", r, "retention_class") == catalog.RETENTION_KEEP_FOREVER
              for r in by_path.values()))
    check("rows carry the jurisdiction default",
          all(field("asset_inventory", r, "jurisdiction") == catalog.JURISDICTION_EU
              for r in by_path.values()))
    check("every row names the run that wrote it",
          all(field("asset_inventory", r, "ingest_run_id") == summary["run_id"]
              for r in by_path.values()))
    check("every row names the dataset it came from",
          all(field("asset_inventory", r, "dataset_id") == "SYNTHETIC — FAKE-DATASET-4271"
              for r in by_path.values()))

    # --- the ledger row -----------------------------------------------------
    ledger = ledger_row(store, summary["run_id"])
    check("the run wrote exactly one ledger row",
          ledger is not None and len(rows(store, "ingest_runs")) == 1)
    if ledger:
        check("the ledger row splits the objects by sensitivity",
              (field("ingest_runs", ledger, "objects_high"),
               field("ingest_runs", ledger, "objects_normal")) == (3, 1))
        check("the ledger row names the KEK the run wrapped with",
              field("ingest_runs", ledger, "kek_version") == 1)
        check("the ledger row names the runner version",
              field("ingest_runs", ledger, "runner_version") == lake_ingest.RUNNER_VERSION)
        check("the ledger row counts plaintext bytes ingested",
              field("ingest_runs", ledger, "bytes_ingested")
              == len(NOTE) + len(INVOICE) + len(PHOTO) + len(TYPO))


# --------------------------------------------------------------------------
# 4. Fail closed on a missing KEK — nothing written, and the refusal is legible.
# --------------------------------------------------------------------------


def test_refuses_high_without_kek():
    s3, bucket = fresh_bucket()
    store = fresh_store()

    with tempfile.TemporaryDirectory() as root:
        # The normal record comes FIRST in the manifest on purpose: without the
        # pre-flight, the runner would write it and only then hit the high
        # record and abort — a half-written load. The assertion below is that
        # even that one object never lands.
        manifest_path = write_manifest(
            root, [("invoice.txt", INVOICE, "normal"), ("note.txt", NOTE, "high")]
        )
        manifest = lake_ingest.load_manifest(manifest_path)
        refused = False
        try:
            lake_ingest.ingest(manifest, s3=s3, bucket=bucket, store=store, kek=None)
        except lake_ingest.MissingKekError:
            refused = True

    check("a manifest containing a high record is refused with no KEK", refused)
    check("nothing was written to the catalog", rows(store, "asset_inventory") == [],
          str(len(rows(store, "asset_inventory"))))
    listed = sorted(stored(s3, bucket))
    check("no object was PUT, including the normal one ahead of the high one",
          not listed, str(listed))

    ledger = rows(store, "ingest_runs")
    check("the refusal is in the ledger as a run, not as silence", len(ledger) == 1,
          str(len(ledger)))
    if ledger:
        check("the refused run's status is 'failed', not 'partial'",
              field("ingest_runs", ledger[0], "status") == catalog.RUN_STATUS_FAILED)
        check("a run that wrote nothing high names no KEK",
              field("ingest_runs", ledger[0], "kek_version") is None)
        check("the refused run still names its dataset and runner",
              field("ingest_runs", ledger[0], "dataset_id") == "SYNTHETIC — FAKE-DATASET-4271"
              and field("ingest_runs", ledger[0], "runner_version") == lake_ingest.RUNNER_VERSION)

    # Fail-closed is not fail-always: an all-normal manifest legitimately needs
    # no key and must load.
    s3, bucket = fresh_bucket()
    store = fresh_store()
    with tempfile.TemporaryDirectory() as root:
        manifest_path = write_manifest(root, [("invoice.txt", INVOICE, "normal")])
        summary = lake_ingest.ingest(
            lake_ingest.load_manifest(manifest_path),
            s3=s3, bucket=bucket, store=store, kek=None,
        )
    check("an all-normal manifest loads with no KEK",
          summary["status"] == catalog.RUN_STATUS_SUCCESS and summary["written_normal"] == 1,
          summary["status"])


# --------------------------------------------------------------------------
# 5. Re-runnable — the property that makes a partial real load resumable.
# --------------------------------------------------------------------------


def test_rerun_is_idempotent(kek):
    s3, bucket = fresh_bucket()
    store = fresh_store()

    with tempfile.TemporaryDirectory() as root:
        manifest_path = write_manifest(
            root,
            [
                ("note.txt", NOTE, "high"),
                ("invoice.txt", INVOICE, "normal"),
                # The same bytes twice under two names: a re-run is not the only
                # way a blob arrives twice, and content-addressing has to
                # collapse the pair inside a single run too.
                ("note-copy.txt", NOTE, "high"),
            ],
        )
        manifest = lake_ingest.load_manifest(manifest_path)

        first = lake_ingest.ingest(manifest, s3=s3, bucket=bucket, store=store, kek=kek)
        check("run 1 collapses the duplicate record within the manifest",
              (first["written_high"], first["written_normal"], first["skipped"]) == (1, 1, 1),
              f"{first['written_high']}/{first['written_normal']}/{first['skipped']}")

        after_first = stored(s3, bucket)
        assets_after_first = rows(store, "asset_inventory", order_by="sha256")

        # Count PUTs directly. The strongest statement of the property is not
        # "the row count did not change" but "the runner did not touch the
        # store": re-encrypting a high blob mints a fresh DEK, so a re-PUT would
        # replace a good ciphertext with one the EXISTING row's wrapped_dek
        # cannot open. That is data loss with a green row count.
        puts = []
        real_put = s3.put_object

        def counting_put(**kwargs):
            puts.append(kwargs["Key"])
            return real_put(**kwargs)

        s3.put_object = counting_put
        try:
            second = lake_ingest.ingest(manifest, s3=s3, bucket=bucket, store=store, kek=kek)
        finally:
            s3.put_object = real_put

        check("run 2 issues no PUT at all", puts == [], str(puts))
        check("run 2 skips every record", second["skipped"] == 3, str(second["skipped"]))
        check("run 2 writes no new asset rows",
              rows(store, "asset_inventory", order_by="sha256") == assets_after_first)
        check("run 2 leaves the stored bytes byte-identical", stored(s3, bucket) == after_first)

        # The ledger still gains a row: a re-run IS an event, and "we ran it
        # again and it was already done" is exactly what a resumable load needs
        # to be able to say afterwards.
        second_ledger = ledger_row(store, second["run_id"])
        check("run 2 still lands in the ledger", second_ledger is not None)
        check("the two runs are distinct ledger rows", len(rows(store, "ingest_runs")) == 2)
        if second_ledger:
            check("run 2's ledger row reports records seen but nothing written",
                  (field("ingest_runs", second_ledger, "files_seen"),
                   field("ingest_runs", second_ledger, "objects_high"),
                   field("ingest_runs", second_ledger, "objects_normal"),
                   field("ingest_runs", second_ledger, "bytes_ingested")) == (3, 0, 0, 0))
            check("run 2 is a success, not a partial — 'already loaded' is not a failure",
                  field("ingest_runs", second_ledger, "status") == catalog.RUN_STATUS_SUCCESS)

        # Resumption proper: a record appended to the manifest after a completed
        # run loads on the next run, and only that record does.
        with open(os.path.join(root, "photo.bin"), "wb") as handle:
            handle.write(PHOTO)
        with open(manifest_path, encoding="utf-8") as handle:
            grown = json.load(handle)
        grown["records"].append({"path": "photo.bin", "sensitivity": "normal"})
        with open(manifest_path, "w", encoding="utf-8") as handle:
            json.dump(grown, handle)

        third = lake_ingest.ingest(
            lake_ingest.load_manifest(manifest_path),
            s3=s3, bucket=bucket, store=store, kek=kek,
        )
        check("run 3 loads only the newly-added record",
              (third["written_normal"], third["written_high"], third["skipped"]) == (1, 0, 3),
              f"{third['written_normal']}/{third['written_high']}/{third['skipped']}")


# --------------------------------------------------------------------------
# 6. One bad record does not lose the other ninety-nine.
# --------------------------------------------------------------------------


def test_unreadable_record_is_partial(kek):
    s3, bucket = fresh_bucket()
    store = fresh_store()

    with tempfile.TemporaryDirectory() as root:
        manifest_path = write_manifest(
            root,
            [
                ("invoice.txt", INVOICE, "normal"),
                ("missing.txt", None, "normal"),
                ("note.txt", NOTE, "high"),
            ],
        )
        summary = lake_ingest.ingest(
            lake_ingest.load_manifest(manifest_path),
            s3=s3, bucket=bucket, store=store, kek=kek,
        )

    check("an unreadable record does not halt the run",
          (summary["written_normal"], summary["written_high"]) == (1, 1),
          f"{summary['written_normal']}/{summary['written_high']}")
    check("the record AFTER the unreadable one still loads",
          any(field("asset_inventory", r, "source_path") == "note.txt"
              for r in rows(store, "asset_inventory")))
    check("the run is reported as partial", summary["status"] == catalog.RUN_STATUS_PARTIAL,
          summary["status"])
    check("the failed record is named by its source path so it can be found",
          [f["source_path"] for f in summary["failed"]] == ["missing.txt"],
          str(summary["failed"]))
    ledger = ledger_row(store, summary["run_id"])
    check("the ledger records the partial outcome",
          ledger is not None and field("ingest_runs", ledger, "status")
          == catalog.RUN_STATUS_PARTIAL)


# --------------------------------------------------------------------------
# Manifest validation — every check here is one the runner would otherwise hit
# mid-load, which is the expensive place to find a typo.
# --------------------------------------------------------------------------


def test_manifest_validation():
    def rejects(payload, label):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "m.json")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(payload if isinstance(payload, str) else json.dumps(payload))
            try:
                lake_ingest.load_manifest(path)
            except lake_ingest.ManifestError:
                check(label, True)
                return
            check(label, False, "loaded without error")

    rejects("{not json", "malformed JSON is rejected")
    rejects({"source": "s", "records": [{"path": "a"}]},
            "a manifest with no dataset_id is rejected")
    rejects({"dataset_id": "d", "records": [{"path": "a"}]},
            "a manifest with no source is rejected")
    rejects({"dataset_id": "d", "source": "s"}, "a manifest with no records is rejected")
    rejects({"dataset_id": "d", "source": "s", "records": [{"mime": "text/plain"}]},
            "a record with no path is rejected")

    with tempfile.TemporaryDirectory() as root:
        manifest_path = write_manifest(root, [("photo.png", PHOTO, "normal")])
        manifest = lake_ingest.load_manifest(manifest_path)
        record = manifest["records"][0]
        check("mime is guessed from the extension when undeclared",
              record["mime"] == "image/png", record["mime"])
        check("kind is derived from the mime when undeclared",
              record["kind"] == "image", record["kind"])
        check("a relative record path resolves against the manifest's directory",
              record["resolved_path"] == os.path.join(root, "photo.png"))
        check("the row records the DECLARED path, not the resolved one",
              record["source_path"] == "photo.png")
        check("defaults come from the catalog contract, not from this module",
              manifest["retention_class"] == catalog.RETENTION_KEEP_FOREVER
              and manifest["jurisdiction"] == catalog.JURISDICTION_EU)

    # A manifest of purely normal records needs no KEK — the pre-flight has to
    # say so, or fail-closed becomes fail-always.
    with tempfile.TemporaryDirectory() as root:
        normal_only = lake_ingest.load_manifest(
            write_manifest(root, [("invoice.txt", INVOICE, "normal")])
        )
        check("an all-normal manifest is reported as needing no KEK",
              not lake_ingest.manifest_needs_kek(normal_only))
    with tempfile.TemporaryDirectory() as root:
        undeclared_only = lake_ingest.load_manifest(
            write_manifest(root, [("photo.bin", PHOTO, UNDECLARED)])
        )
        check("a manifest with an undeclared record is reported as needing a KEK",
              lake_ingest.manifest_needs_kek(undeclared_only))


# --------------------------------------------------------------------------


@mock_aws
def main():
    kek = os.urandom(32)  # ephemeral, synthetic, never persisted

    print("sensitivity resolution + encrypt-on-PUT:")
    test_sensitivity_and_encryption(kek)
    print("\nfail-closed KEK refusal:")
    test_refuses_high_without_kek()
    print("\nre-runnable / resumable:")
    test_rerun_is_idempotent(kek)
    print("\npartial run on an unreadable record:")
    test_unreadable_record_is_partial(kek)
    print("\nmanifest validation:")
    test_manifest_validation()

    print()
    if FAILED:
        print(f"FAILED: {FAILED} failed, {PASSED} passed")
        return 1
    print(f"{PASSED} passed, 0 failed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
