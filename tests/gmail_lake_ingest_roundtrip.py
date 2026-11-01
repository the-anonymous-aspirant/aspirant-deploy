"""B1's Gmail export through the real ingest runner, under moto S3 + DuckDB.

system_3 #8810 (`#8806-B2`). The pull (#8806-B1, `scripts/gmail/gmail_pull.py`)
writes one run directory holding `messages.json` and the manifest
`scripts/lake_ingest.py` loads. This drives that manifest through the runner
with an ephemeral KEK and proves, byte by byte:

  - the manifest describes the `gmail` dataset the way the catalog contract
    expects (`message_export`, declared `high`, the 2026-07-18 defaults for
    retention and jurisdiction);
  - without a KEK the pre-flight refuses and nothing is PUT or catalogued;
  - with one, the stored object is an `AOBJ` envelope that no plaintext sniff
    recognises, while the export it came from is `readable JSON`;
  - the inventory row carries everything `verify-at-rest` needs and the
    harness (`scripts/lake_verify_at_rest.py`) is green over the bucket, checks
    0-7;
  - the envelope decrypts back to the export's exact bytes;
  - an incremental run is a second object, and a re-run of the first skips it.

The export is built from the synthetic mailbox in `tests/fixtures/gmail/` with
the pull's own normaliser and writer (`normalize_message`, `write_run`), so the
manifest under test is the one the pull produces, not a copy of it. `moto`
stands in for Garage, exactly as `tests/lake_ingest_roundtrip.py` does; the
helpers come from that harness so the two tests cannot drift apart. Every KEK
is `os.urandom(32)`, never persisted. No real mail, no real key.

Run in the container: tests/gmail_lake_ingest_unit.sh.
"""

import base64
import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from moto import mock_aws

_REPO = Path(__file__).resolve().parents[1]
for _p in ("scripts", "scripts/kek", "scripts/lake", "scripts/gmail", "tests"):
    sys.path.insert(0, str(_REPO / _p))

import catalog  # noqa: E402
import dek_envelope  # noqa: E402
import gmail_pull  # noqa: E402
import lake_ingest  # noqa: E402
import lake_ingest_roundtrip as harness  # noqa: E402  (fresh_store, fresh_bucket, rows, field, stored, check)
import lake_verify_at_rest as at_rest  # noqa: E402
from envelope_store import decrypt_from_storage  # noqa: E402

FIXTURE = json.loads((_REPO / "tests" / "fixtures" / "gmail" / "mailbox.json").read_text("utf-8"))
check = harness.check


def export_from(snapshot: str, *, mode: str = "full", base: str | None = None, deleted=()) -> dict:
    """What `full_pull` / `incremental_pull` return for a fixture snapshot, built
    with the pull's own normaliser so the export shape is the pull's."""
    messages = [
        gmail_pull.normalize_message(m)
        for m in FIXTURE[snapshot]["messages"]
        if not gmail_pull.is_excluded(m)
    ]
    return {
        "mode": mode,
        "base_history_id": base,
        "history_id": str(FIXTURE[snapshot]["history_id"]),
        "messages": messages,
        "deleted_ids": list(deleted),
        "counts": {},
    }


def write_fixture_run(staging: Path, run_id: str, export: dict) -> Path:
    now = datetime(2026, 11, 1, 12, 0, 0, tzinfo=timezone.utc)
    return gmail_pull.write_run(staging, run_id, export, now)


def asset_dicts(store):
    cols = catalog.ASSET_INVENTORY_FIELDS
    return [dict(zip(cols, r)) for r in harness.rows(store, "asset_inventory", order_by="ingested_at")]


def test_manifest_is_the_gmail_dataset(run_dir: Path):
    manifest = lake_ingest.load_manifest(str(run_dir / gmail_pull.MANIFEST_NAME))
    check("dataset_id is gmail", manifest["dataset_id"] == "gmail", manifest["dataset_id"])
    check("source names the mailbox and the run", manifest["source"].startswith("gmail:users/me"), manifest["source"])
    check("one record: the export", len(manifest["records"]) == 1 and manifest["records"][0]["source_path"] == gmail_pull.EXPORT_NAME)
    rec = manifest["records"][0]
    check("kind message_export", rec["kind"] == "message_export", rec["kind"])
    check("declared sensitivity high", rec["declared_sensitivity"] == "high", rec["declared_sensitivity"])
    check("mime application/json", rec["mime"] == "application/json", rec["mime"])
    check("retention defaults to keep-forever", manifest["retention_class"] == catalog.RETENTION_KEEP_FOREVER)
    check("jurisdiction defaults to EU", manifest["jurisdiction"] == catalog.JURISDICTION_EU)
    check("the manifest needs a KEK", lake_ingest.manifest_needs_kek(manifest) is True)
    return manifest


def test_refuses_without_kek(manifest: dict):
    store = harness.fresh_store()
    s3, bucket = harness.fresh_bucket()
    refused = False
    try:
        lake_ingest.ingest(manifest, s3=s3, bucket=bucket, store=store, kek=None)
    except lake_ingest.MissingKekError:
        refused = True
    check("no KEK: the pre-flight refuses", refused)
    check("no KEK: nothing was PUT", harness.stored(s3, bucket) == {})
    check("no KEK: no asset row", harness.rows(store, "asset_inventory") == [])
    runs = harness.rows(store, "ingest_runs")
    check("no KEK: one failed ledger row", len(runs) == 1 and harness.field("ingest_runs", runs[0], "status") == catalog.RUN_STATUS_FAILED,
          [harness.field("ingest_runs", r, "status") for r in runs])


def test_encrypted_write_and_verify(manifest: dict, run_dir: Path, kek: bytes):
    store = harness.fresh_store()
    s3, bucket = harness.fresh_bucket()
    export_bytes = (run_dir / gmail_pull.EXPORT_NAME).read_bytes()
    summary = lake_ingest.ingest(manifest, s3=s3, bucket=bucket, store=store, kek=kek, kek_version=1)
    check("with the KEK: the run succeeds", summary["status"] == catalog.RUN_STATUS_SUCCESS, summary["status"])

    objects = harness.stored(s3, bucket)
    check("exactly one object was PUT", len(objects) == 1, sorted(objects))
    key, body = next(iter(objects.items()))
    check("the key sits under bronze/blobs/sha256/", key.startswith(lake_ingest.BLOB_PREFIX + "/"), key)
    check("the stored bytes start with the AOBJ magic", body[:4] == b"AOBJ", body[:8])
    check("no plaintext sniff recognises the stored object", at_rest.describe_plaintext(body) is None, at_rest.describe_plaintext(body))
    check("the export itself IS readable JSON (so check 3 would name a plaintext write)",
          at_rest.describe_plaintext(export_bytes) == "readable JSON", at_rest.describe_plaintext(export_bytes))
    parses = True
    try:
        json.loads(body)
    except ValueError:
        parses = False
    check("the stored object does not parse as JSON", not parses)
    check("the stored object is not the export", body != export_bytes and export_bytes not in body)

    rows = asset_dicts(store)
    check("one asset_inventory row", len(rows) == 1, len(rows))
    row = rows[0]
    expected = {
        "sensitivity": catalog.SENSITIVITY_HIGH,
        "sensitivity_source": catalog.SOURCE_DECLARED,
        "kind": "message_export",
        "dataset_id": "gmail",
        "retention_class": catalog.RETENTION_KEEP_FOREVER,
        "jurisdiction": catalog.JURISDICTION_EU,
        "kek_version": 1,
        "object_key": key,
        "source_path": gmail_pull.EXPORT_NAME,
        "mime": "application/json",
        "size_bytes": len(export_bytes),
        "sha256": hashlib.sha256(export_bytes).hexdigest(),
    }
    for name, want in expected.items():
        check(f"row.{name} == {want!r}", row.get(name) == want, row.get(name))
    check("row carries a wrapped DEK", bool(row.get("wrapped_dek")))
    runs = harness.rows(store, "ingest_runs")
    check("one success ledger row", len(runs) == 1 and harness.field("ingest_runs", runs[0], "status") == catalog.RUN_STATUS_SUCCESS)

    # verify-at-rest over the bucket, with the KEK in custody: checks 0-7.
    def fetch(object_key):
        return s3.get_object(Bucket=bucket, Key=object_key)["Body"].read()

    findings = at_rest.verify(
        rows,
        fetch,
        unwrap=lambda wrapped: dek_envelope.unwrap_dek(wrapped, kek),
        decrypt=dek_envelope.decrypt_object,
        stored_keys=list(objects),
    )
    green, counts = at_rest.verdict(findings)
    bad = [f.as_dict() for f in findings if f.status != at_rest.PASS]
    check("verify-at-rest is GREEN over the gmail object", green, bad)
    check("verify-at-rest ran check 6 (decrypts to content address)",
          any(f.check == at_rest.CHECK_DECRYPTS_TO_CONTENT and f.status == at_rest.PASS for f in findings))
    check("verify-at-rest ran check 7 (no uncatalogued object)",
          any(f.check == at_rest.CHECK_UNCATALOGUED for f in findings) or counts.get("7-uncatalogued-object", 0) == 0)

    # The envelope decrypts back to the export, exactly.
    plaintext = decrypt_from_storage(body, row["wrapped_dek"], lambda version: kek)
    check("decrypt_from_storage returns the export bytes", plaintext == export_bytes)
    check("the row's sha256 is the plaintext digest", hashlib.sha256(plaintext).hexdigest() == row["sha256"])

    # A wrong KEK never returns garbage.
    wrong = False
    try:
        decrypt_from_storage(body, row["wrapped_dek"], lambda version: os.urandom(32))
    except dek_envelope.EnvelopeError:
        wrong = True
    check("a wrong KEK raises rather than returning bytes", wrong)
    return store, s3, bucket


def test_incremental_run_and_rerun(store, s3, bucket, staging: Path, kek: bytes, first_manifest: dict):
    delta = export_from("s2", mode="incremental", base=str(FIXTURE["s1"]["history_id"]), deleted=["18f0000000000004"])
    run2 = write_fixture_run(staging, "20261101T121500Z-incremental", delta)
    manifest2 = lake_ingest.load_manifest(str(run2 / gmail_pull.MANIFEST_NAME))
    check("the incremental manifest is the same dataset", manifest2["dataset_id"] == "gmail")
    summary = lake_ingest.ingest(manifest2, s3=s3, bucket=bucket, store=store, kek=kek, kek_version=1)
    check("the incremental run succeeds", summary["status"] == catalog.RUN_STATUS_SUCCESS, summary["status"])
    objects = harness.stored(s3, bucket)
    check("the incremental export is a second object", len(objects) == 2, sorted(objects))
    check("every stored object is an envelope", all(b[:4] == b"AOBJ" for b in objects.values()))
    rows = asset_dicts(store)
    check("two asset rows, both gmail / high / message_export",
          len(rows) == 2 and all(r["dataset_id"] == "gmail" and r["sensitivity"] == "high" and r["kind"] == "message_export" for r in rows))
    base = (
        base64.b64decode(rows[0]["wrapped_dek"]),
        base64.b64decode(rows[1]["wrapped_dek"]),
    )
    check("each object has its own DEK", base[0] != base[1])

    again = lake_ingest.ingest(first_manifest, s3=s3, bucket=bucket, store=store, kek=kek, kek_version=1)
    check("re-running the first manifest succeeds", again["status"] == catalog.RUN_STATUS_SUCCESS)
    check("re-running the first manifest PUTs nothing new", len(harness.stored(s3, bucket)) == 2)
    check("re-running the first manifest adds no asset row", len(asset_dicts(store)) == 2)
    check("the ledger has three runs", len(harness.rows(store, "ingest_runs")) == 3)


@mock_aws
def main() -> int:
    kek = os.urandom(32)  # ephemeral, synthetic, never persisted
    with tempfile.TemporaryDirectory() as tmp:
        staging = Path(tmp) / "gmail"
        run1 = write_fixture_run(staging, "20261101T120000Z-full", export_from("s1"))
        print("the pull's manifest describes the gmail dataset:")
        manifest = test_manifest_is_the_gmail_dataset(run1)
        print("\nfail-closed without a KEK:")
        test_refuses_without_kek(manifest)
        print("\nencrypted write, catalog row, verify-at-rest, decrypt:")
        store, s3, bucket = test_encrypted_write_and_verify(manifest, run1, kek)
        print("\nincremental run and re-run:")
        test_incremental_run_and_rerun(store, s3, bucket, staging, kek, manifest)
    print()
    if harness.FAILED:
        print(f"FAILED: {harness.FAILED} failed, {harness.PASSED} passed")
        return 1
    print(f"{harness.PASSED} passed, 0 failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
