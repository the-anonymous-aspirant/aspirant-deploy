"""Prove the §9 at-rest property through a real S3 PUT/GET hop.

Task #4134 (#4120-D). DATA_LAKE_DESIGN.md §9 layer 2 success criterion: "read the
raw Garage object; it is NOT plaintext". This exercises the ingest encrypt path
(`envelope_store.storage_body_and_wrapped_dek` + a real `boto3` `put_object`)
against an in-process S3 (`moto`), then reads the raw stored object back through
the S3 API and asserts it is AOBJ ciphertext — the same shape the fixtures loader
PUTs to Garage. `moto` stands in for Garage so this needs no compose stack; the
live Garage round-trip against a real bucket is the joint acceptance with the
explorer decrypt half (#4199).

Ephemeral synthetic KEK only — no production key material.

Run in the container test (tests/envelope_ingest_unit.sh) with `moto` + `boto3` +
`cryptography` installed.
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "kek"))

import boto3
from moto import mock_aws

from envelope_store import decrypt_from_storage, storage_body_and_wrapped_dek

BUCKET = "lake-skeleton-bronze"


def _put_get(sensitivity: str, payload: bytes, kek: bytes):
    """Ingest one blob through the encrypt gate; return the raw stored bytes and
    the wrapped DEK the inventory row would carry."""
    stored_body, wrapped_dek = storage_body_and_wrapped_dek(
        payload, sensitivity, kek, kek_version=1
    )
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket=BUCKET)
    key = "bronze/blobs/sha256/de/ad/deadbeef"
    s3.put_object(Bucket=BUCKET, Key=key, Body=stored_body)
    raw = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    return raw, wrapped_dek


@mock_aws
def main() -> int:
    passed = 0
    failed = 0

    def check(label, cond):
        nonlocal passed, failed
        if cond:
            passed += 1
            print(f"[PASS] {label}")
        else:
            failed += 1
            print(f"[FAIL] {label}")

    kek = os.urandom(32)
    plaintext = b"SYNTHETIC MEDICAL NOTE - NOT REAL. Patient: SYNTHETIC - Bob Doesnotexist"

    # sensitivity=high: the raw object in the store is ciphertext, not plaintext.
    raw_high, wrapped = _put_get("high", plaintext, kek)
    check("raw high object carries the AOBJ header", raw_high[:4] == b"AOBJ")
    check("raw high object does not contain the plaintext", plaintext not in raw_high)
    check("high blob carries a wrapped DEK for the inventory row", wrapped is not None)
    check(
        "read-back decrypts byte-identical to the original",
        decrypt_from_storage(raw_high, wrapped, lambda _v: kek) == plaintext,
    )

    # sensitivity=normal: stored as-is (the gate must not encrypt it).
    raw_normal, wrapped_normal = _put_get("normal", plaintext, kek)
    check("raw normal object is the plaintext", raw_normal == plaintext)
    check("normal blob has no wrapped DEK", wrapped_normal is None)

    print()
    if failed:
        print(f"FAILED: {failed} failed, {passed} passed")
        return 1
    print(f"{passed} passed, 0 failed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
