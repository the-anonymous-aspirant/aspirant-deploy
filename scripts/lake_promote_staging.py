"""Promote verified staged uploads into bronze: catalog, encrypt by sensitivity, clean up.

DATA_LAKE_DESIGN.md §2 (bronze blobs + blob catalog), §8.6 (connector ledger),
§9 (layer 2 envelope encryption). Task **#9758** (`#9546-A2`), child E2 of the
explorer-upload epic #4121 (`#9546`, child E). Design: #9546 c59561/c59562.

Why this exists
----------------
#9547 (child C, aspirant-explorer) lands an uploaded file's assembled bytes and
a manifest at ``bronze/staging/<upload_id>/`` in the staging bucket, through a
write-only key (#9545/B) that cannot read what it just wrote. Nothing reads
that bucket back into the durable, catalogued lake — this is that reader.

Mirrors `lake_ingest.py`'s shape deliberately: the same fail-closed KEK
pre-flight, the same catalog-row-is-the-commit-marker ordering, the same
partial-run-on-one-bad-record tolerance. It differs in two ways a real-file
loader does not have to: the claimed digest is untrusted until re-verified
(an upload is attacker-reachable in a way a local manifest path is not), and a
`high` object is wrapped by streaming through a `/scratch` spool rather than
built in memory (#9546-A1), because an upload can be gigabytes and this
process holds only one chunk at a time.

The staged layout and the manifest schema are documented in
`docs/data-lake-design/STAGING_PROMOTION.md`.

The three properties worth reading the code for (same as `lake_ingest.py`)
----------------------------------------------------------------------------
**1. Fail closed, twice.** Every staged manifest is read in a pre-flight pass
before any object GET; if any resolves to `high` and no KEK is loaded, the
whole run refuses and writes nothing, with a `failed` ledger row.

**2. The catalog row is the commit marker.** The object is written to bronze
(copied, or encrypted-and-PUT) *then* the `asset_inventory` row is written,
*then* the staged object and its manifest are deleted. A crash between any two
steps leaves evidence a re-run can act on: between PUT and row, an orphan
bronze object the next run's re-PUT (same content address) repairs; between
row and delete, a staged duplicate the next run's skip-and-clean step removes.

**3. One bad upload does not lose the rest.** A hash mismatch, an unreadable
manifest, or a truncated spool is recorded by `upload_id` and stepped over;
the run finishes `partial`.

Usage
-----
    python scripts/lake_promote_staging.py [--dry-run]

    scripts/lake-skeleton.sh promote [--dry-run]   # via the container
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from typing import Any

# Mirrors lake_ingest.py: the envelope machinery and the catalog contract live
# beside this script on disk, and mounted at /work/kek and /work/lake in the
# client container. Imported, never re-derived.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "kek"))
sys.path.insert(0, os.path.join(_HERE, "lake"))

from envelope_store import encrypt_for_storage_stream  # noqa: E402
from kek_loader import ENV_KEK_FINGERPRINT, ENV_KEK_HEX, load_kek_from_env  # noqa: E402

import catalog  # noqa: E402

# lake_ingest.py owns the DuckDB catalog-store wrapper (ensure_tables' schema-
# drift guard, the skip-set reader, add_asset/add_run); this is the same
# asset_inventory + ingest_runs contract, so this runner reuses it rather than
# carrying a second copy that could drift from the first (#4270's whole point).
sys.path.insert(0, _HERE)
from lake_ingest import CatalogSchemaError, DuckDBCatalogStore, _NullStore  # noqa: E402

#: Recorded in every `ingest_runs` row this writer produces.
RUNNER_VERSION = "lake-promote-staging-1.0.0"

DEFAULT_KEK_VERSION = 1

#: §2's content-addressed bronze layout — identical to lake_ingest.py's.
BLOB_PREFIX = "bronze/blobs/sha256"

#: The staged-upload layout this runner reads and deletes. See
#: STAGING_PROMOTION.md for the full contract.
STAGING_PREFIX = "bronze/staging/"
OBJECT_NAME = "object"
MANIFEST_NAME = "manifest.json"

#: The promotion SWEEP's own ledger dataset_id. A single run can promote
#: uploads from several intake buckets (several real "datasets"); each
#: promoted asset_inventory row keeps its own per-bucket dataset_id
#: (`explorer-upload:<bucket>`) instead. See STAGING_PROMOTION.md.
PROMOTION_DATASET_ID = "explorer-staging"

REQUIRED_MANIFEST_FIELDS = (
    "claimed_sha256", "bucket", "sensitivity", "source_filename", "mime",
    "size_bytes", "upload_time",
)

#: #9547's own bucket -> sensitivity map, duplicated here (security review of
#: this PR, c63351): the map is applied once at upload time (#9547) but this
#: runner is the last check before bronze, and a manifest's own `sensitivity`
#: field is exactly as untrusted as its `claimed_sha256` — both are written by
#: the same caller. An upload promotes under the STRICTER of its declared
#: sensitivity and this map, never the looser one. An unrecognised bucket maps
#: to `high`, matching `catalog.resolve_sensitivity`'s own fail-closed default.
BUCKET_SENSITIVITY = {
    "photos": catalog.SENSITIVITY_HIGH,
    "finance": catalog.SENSITIVITY_HIGH,
    "medical": catalog.SENSITIVITY_HIGH,
    "docs": catalog.SENSITIVITY_NORMAL,
    "general": catalog.SENSITIVITY_NORMAL,
}

#: `claimed_sha256` must look like a sha256 hex digest before it is ever used
#: as a dict key or a blob-key component (security review c63351).
_SHA256_HEX_RE = re.compile(r"^[0-9a-f]{64}$")

#: Streamed-read chunk size for both the verify pass and the encrypt pass.
#: Bounds resident memory near one chunk regardless of object size (#9546-A1).
STREAM_CHUNK = 8 * 1024 * 1024


class ManifestError(ValueError):
    """A staged manifest is missing, unreadable, or incomplete.

    Recorded per-upload and stepped over — a bad manifest does not abort the
    run, matching `lake_ingest.py`'s "one bad record" tolerance.
    """


class MissingKekError(RuntimeError):
    """A staged `high` upload must be promoted and no KEK is loaded.

    Deliberately NOT a per-upload failure: a systemic refusal aborts the whole
    run before any object is touched, because continuing would refuse every
    remaining `high` upload one at a time and promote none of them.
    """


class SpoolMismatchError(RuntimeError):
    """The bytes actually streamed into the `/scratch` spool do not match the
    claimed digest — a second, independent check of the same property
    `verify_staged_object` already checked once, closing the gap between that
    read and this one."""


class CopyMismatchError(RuntimeError):
    """The bronze copy of a `normal` object, re-hashed after `copy_object`,
    does not match the claimed digest (security review c63351).

    `verify_staged_object`'s read and the server-side copy are two separate
    moments; anything that overwrites the staged object in between is copied
    under the content address of the bytes it replaced. Re-hashing the
    DESTINATION closes this: the uploader's key cannot write bronze, so that
    read is final regardless of what happened to the staging copy.
    """


def _kind_for(mime: str) -> str:
    """A coarse `kind` from the uploaded file's MIME type. Mirrors
    `lake_ingest.py::_kind_for` — duplicated rather than imported because it is
    six lines and importing a leading-underscore name across scripts is a
    worse coupling than the duplication."""
    if mime.startswith("image/"):
        return "image"
    if mime.startswith("audio/"):
        return "audio"
    if mime.startswith("video/"):
        return "video"
    if mime.startswith("text/") or mime in ("application/pdf", "application/msword"):
        return "document"
    return "blob"


def _blob_key(digest: str) -> str:
    return f"{BLOB_PREFIX}/{digest[:2]}/{digest[2:4]}/{digest}"


def _object_key(upload_id: str) -> str:
    return f"{STAGING_PREFIX}{upload_id}/{OBJECT_NAME}"


def _manifest_key(upload_id: str) -> str:
    return f"{STAGING_PREFIX}{upload_id}/{MANIFEST_NAME}"


# --------------------------------------------------------------------------
# Staged uploads — what is waiting, and what each one claims about itself.
# --------------------------------------------------------------------------


def list_staged_uploads(s3, staging_bucket: str) -> list[str]:
    """Every `upload_id` with a staged object today, sorted for a stable order.

    One listing call (paginated), not a per-upload existence probe: `Delimiter`
    groups keys under `bronze/staging/<upload_id>/` into one `CommonPrefixes`
    entry per upload, which is the "list of folders" a raw key listing does
    not give directly.
    """
    upload_ids = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=staging_bucket, Prefix=STAGING_PREFIX, Delimiter="/"):
        for entry in page.get("CommonPrefixes") or []:
            upload_id = entry["Prefix"][len(STAGING_PREFIX):].rstrip("/")
            if upload_id:
                upload_ids.append(upload_id)
    return sorted(upload_ids)


def read_manifest(s3, staging_bucket: str, upload_id: str) -> dict[str, Any]:
    """The staged manifest for `upload_id`, validated against the contract.

    Validated up front — same reasoning as `lake_ingest.load_manifest`: a
    malformed manifest found here costs one line in the failure list; found
    mid-promotion it costs a half-finished object.
    """
    try:
        body = s3.get_object(Bucket=staging_bucket, Key=_manifest_key(upload_id))["Body"].read()
    except Exception as exc:  # noqa: BLE001 - any backend error means "not readable"
        raise ManifestError(f"upload {upload_id}: cannot read manifest: {exc}") from exc
    try:
        raw = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise ManifestError(f"upload {upload_id}: manifest is not valid JSON: {exc}") from exc
    if not isinstance(raw, dict):
        raise ManifestError(f"upload {upload_id}: manifest must be a JSON object")
    missing = [field for field in REQUIRED_MANIFEST_FIELDS if field not in raw]
    if missing:
        raise ManifestError(f"upload {upload_id}: manifest missing required field(s) {missing}")

    # Type/format validation (security review c63351): a manifest is as
    # untrusted as the upload it describes. Catching a malshaped field here,
    # where it is one failed upload, is the whole point — the alternative is
    # discovering it as a TypeError on `in known` or an AttributeError on
    # `.startswith()` after bronze has already been written.
    if not isinstance(raw["claimed_sha256"], str) or not _SHA256_HEX_RE.match(raw["claimed_sha256"]):
        raise ManifestError(
            f"upload {upload_id}: claimed_sha256 is not a 64-character hex digest: "
            f"{raw['claimed_sha256']!r}"
        )
    for field in ("bucket", "sensitivity", "source_filename", "mime", "upload_time"):
        if not isinstance(raw[field], str) or not raw[field]:
            raise ManifestError(f"upload {upload_id}: {field} must be a non-empty string, got {raw[field]!r}")
    if not isinstance(raw["size_bytes"], int) or isinstance(raw["size_bytes"], bool) or raw["size_bytes"] < 0:
        raise ManifestError(f"upload {upload_id}: size_bytes must be a non-negative integer, got {raw['size_bytes']!r}")
    return raw


def resolve_upload_sensitivity(manifest: dict[str, Any]) -> tuple[str, str]:
    """The sensitivity an upload promotes under, and why.

    The STRICTER of the manifest's own declared `sensitivity` (fail-closed via
    `catalog.resolve_sensitivity`) and `BUCKET_SENSITIVITY[bucket]` — never the
    looser one (security review c63351). Both inputs come from the same
    untrusted manifest; a writer that declares `normal` for a `medical` upload
    must not get a plaintext write just because it said so.
    """
    declared, declared_source = catalog.resolve_sensitivity(manifest["sensitivity"])
    mapped = BUCKET_SENSITIVITY.get(manifest["bucket"], catalog.SENSITIVITY_HIGH)
    if mapped == catalog.SENSITIVITY_HIGH and declared != catalog.SENSITIVITY_HIGH:
        return catalog.SENSITIVITY_HIGH, f"defaulted:bucket_map_overrides:{manifest['bucket']}"
    return declared, declared_source


def manifests_need_kek(manifests: dict[str, dict[str, Any]]) -> bool:
    """Would promoting these manifests write at least one `high` blob?

    Answerable without a single object GET, which is what makes the pre-flight
    refusal possible before any byte moves.
    """
    return any(
        resolve_upload_sensitivity(m)[0] == catalog.SENSITIVITY_HIGH
        for m in manifests.values()
    )


# --------------------------------------------------------------------------
# Verify — the claimed digest is untrusted until a streamed re-read confirms it.
# --------------------------------------------------------------------------


def verify_staged_object(s3, staging_bucket: str, upload_id: str, claimed_sha256: str) -> tuple[bool, int]:
    """Stream the staged object once, hash it, compare to the claim.

    Returns `(matches, actual_size_bytes)`. The size is the REAL byte count
    observed on this read, never the manifest's declared `size_bytes` — the
    same "size_bytes is of the bytes actually handled" property
    `lake_ingest.py` keeps for its own records.
    """
    body = s3.get_object(Bucket=staging_bucket, Key=_object_key(upload_id))["Body"]
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = body.read(STREAM_CHUNK)
        if not chunk:
            break
        digest.update(chunk)
        total += len(chunk)
    return digest.hexdigest() == claimed_sha256, total


# --------------------------------------------------------------------------
# Promote — normal via server-side copy; high via a streamed /scratch spool.
# --------------------------------------------------------------------------


def promote_normal(s3, staging_bucket: str, bucket: str, upload_id: str, digest: str) -> str:
    """Server-side copy: bronze is the destination, this process is never in
    the data path for the bytes themselves.

    `verify_staged_object`'s earlier read and this copy are two separate
    moments on the staging side, so the copy is re-verified at its
    DESTINATION afterward (security review c63351): the uploader's key
    cannot write bronze, so a hash of the bronze object is final regardless
    of what happened to the staging copy in between. A mismatch deletes the
    bronze object and raises — nothing is left half-promoted.
    """
    key = _blob_key(digest)
    s3.copy_object(
        Bucket=bucket, Key=key,
        CopySource={"Bucket": staging_bucket, "Key": _object_key(upload_id)},
    )
    verify_body = s3.get_object(Bucket=bucket, Key=key)["Body"]
    actual = hashlib.sha256()
    while True:
        chunk = verify_body.read(STREAM_CHUNK)
        if not chunk:
            break
        actual.update(chunk)
    if actual.hexdigest() != digest:
        s3.delete_object(Bucket=bucket, Key=key)
        raise CopyMismatchError(
            f"upload {upload_id}: the bronze copy does not match the claimed sha256 "
            f"— the staged object changed between verify and copy; the bronze object "
            f"was deleted and nothing was catalogued"
        )
    return key


def promote_high(
    s3, staging_bucket: str, bucket: str, upload_id: str, claimed_sha256: str,
    kek: bytes, kek_version: int, spool_dir: str,
) -> tuple[str, str]:
    """Stream-encrypt the staged object into a `/scratch` spool, re-verify the
    digest against the bytes actually streamed, then PUT the spool.

    Plaintext never touches an unencrypted disk: the spool directory is on
    `/scratch` (LUKS at rest, per KEK_CEREMONY.md), and it holds ciphertext —
    `encrypt_for_storage_stream` writes `dst` the AOBJ bytes, never the
    plaintext chunks it reads from `src`.
    """
    key = _blob_key(claimed_sha256)
    digest = hashlib.sha256()
    fd, spool_path = tempfile.mkstemp(dir=spool_dir, prefix=f"promote-{upload_id}-")
    try:
        with os.fdopen(fd, "wb") as spool:
            body = s3.get_object(Bucket=staging_bucket, Key=_object_key(upload_id))["Body"]
            _total, wrapped_dek_b64 = encrypt_for_storage_stream(
                body, spool, kek, kek_version, plaintext_hash=digest
            )
        if digest.hexdigest() != claimed_sha256:
            raise SpoolMismatchError(
                f"upload {upload_id}: the bytes streamed into the spool do not match "
                f"the claimed sha256 (checked independently of the earlier verify pass)"
            )
        with open(spool_path, "rb") as spool_read:
            s3.put_object(Bucket=bucket, Key=key, Body=spool_read)
    finally:
        os.unlink(spool_path)
    return key, wrapped_dek_b64


# --------------------------------------------------------------------------
# The run.
# --------------------------------------------------------------------------


def new_run_id(now: datetime) -> str:
    return f"PROMOTE-{now.strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"


def promote(
    *,
    s3,
    staging_bucket: str,
    bucket: str,
    store,
    kek: bytes | None = None,
    kek_version: int = DEFAULT_KEK_VERSION,
    spool_dir: str = "/scratch-spool",
    now: datetime | None = None,
    run_id: str | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    """Promote every staged upload, and write the run to the ledger.

    Returns a summary dict (the same numbers the ledger row carries, plus the
    per-upload detail the ledger has no column for). Raises `MissingKekError`
    *after* writing a `failed` ledger row — same reasoning as `lake_ingest.py`:
    a run that refused must be visible in the ledger.
    """
    now = now or datetime.now(timezone.utc)
    run_id = run_id or new_run_id(now)
    promoted_at = now.strftime("%Y-%m-%d %H:%M:%S")
    started = time.monotonic()

    store.ensure_tables()
    known = store.known_sha256()

    summary: dict[str, Any] = {
        "run_id": run_id,
        "dataset_id": PROMOTION_DATASET_ID,
        "uploads_seen": 0,
        "written_high": 0,
        "written_normal": 0,
        "skipped": 0,
        "failed": [],
        "bytes_promoted": 0,
        "dry_run": dry_run,
    }

    def finish(status: str) -> dict[str, Any]:
        summary["status"] = status
        summary["duration_seconds"] = round(time.monotonic() - started, 3)
        if not dry_run:
            store.add_run(
                catalog.run_row(
                    run_id=run_id,
                    source="explorer-staging-promotion",
                    started_on=promoted_at,
                    duration_seconds=summary["duration_seconds"],
                    files_seen=summary["uploads_seen"],
                    bytes_ingested=summary["bytes_promoted"],
                    status=status,
                    dataset_id=PROMOTION_DATASET_ID,
                    runner_version=RUNNER_VERSION,
                    kek_version=kek_version if summary["written_high"] else None,
                    objects_high=summary["written_high"],
                    objects_normal=summary["written_normal"],
                )
            )
        return summary

    upload_ids = list_staged_uploads(s3, staging_bucket)
    summary["uploads_seen"] = len(upload_ids)

    manifests: dict[str, dict[str, Any]] = {}
    for upload_id in upload_ids:
        try:
            manifests[upload_id] = read_manifest(s3, staging_bucket, upload_id)
        except ManifestError as exc:
            summary["failed"].append({"upload_id": upload_id, "error": str(exc)})

    # --- pre-flight: refuse the whole run before touching a single object ---
    if kek is None and manifests_need_kek(manifests):
        finish(catalog.RUN_STATUS_FAILED)
        raise MissingKekError(
            "refusing to promote: at least one staged upload declares "
            "sensitivity=high (or defaults to it under the fail-closed intake "
            f"rule) and no KEK is loaded. Set {ENV_KEK_HEX} to the off-cell "
            f"grouped hex (never on disk). Nothing was written; run {run_id} "
            "is in the ledger as failed."
        )

    for upload_id, manifest in manifests.items():
        claimed_sha256 = manifest["claimed_sha256"]

        if claimed_sha256 in known:
            # Already catalogued — a leftover staged duplicate from a run that
            # crashed between the row and the delete (property 2). The next
            # run's job is to finish that delete, not re-promote.
            if not dry_run:
                s3.delete_object(Bucket=staging_bucket, Key=_object_key(upload_id))
                s3.delete_object(Bucket=staging_bucket, Key=_manifest_key(upload_id))
            summary["skipped"] += 1
            continue

        sensitivity, sensitivity_source = resolve_upload_sensitivity(manifest)
        is_high = sensitivity == catalog.SENSITIVITY_HIGH

        if is_high and kek is None:
            # Belt and braces over the pre-flight, as in lake_ingest.py: this
            # reads the resolved decision for the upload actually in hand.
            # NOT inside the broad per-upload guard below — a systemic
            # refusal aborts the whole run, it is never "one failed upload".
            finish(catalog.RUN_STATUS_FAILED)
            raise MissingKekError(
                f"refusing to promote sensitivity=high upload {upload_id} with no KEK loaded"
            )

        # Everything from here is per-upload: ANY exception — a verify
        # mismatch, a spool mismatch, a copy mismatch, or anything this
        # function did not anticipate (a missing staged object, a backend
        # error) — is recorded against this upload_id and the run continues
        # to the next one (property 3; security review c63351 P2, which found
        # several uncaught-exception paths that previously aborted the whole
        # run with no ledger row).
        try:
            matched, actual_size = verify_staged_object(s3, staging_bucket, upload_id, claimed_sha256)
            if not matched:
                raise ValueError("claimed sha256 does not match the staged object's bytes")

            if dry_run:
                known.add(claimed_sha256)
                summary["written_high" if is_high else "written_normal"] += 1
                summary["bytes_promoted"] += actual_size
                continue

            if is_high:
                object_key, wrapped_dek = promote_high(
                    s3, staging_bucket, bucket, upload_id, claimed_sha256, kek, kek_version, spool_dir
                )
            else:
                object_key = promote_normal(s3, staging_bucket, bucket, upload_id, claimed_sha256)
                wrapped_dek = None

            # Row, then delete — the row is the commit marker (property 2);
            # the staged copy is cleanup, not the record of what happened.
            store.add_asset(
                catalog.asset_row(
                    sha256=claimed_sha256,
                    object_key=object_key,
                    source_path=manifest["source_filename"],
                    mime=manifest["mime"],
                    size_bytes=actual_size,
                    kind=_kind_for(manifest["mime"]),
                    sensitivity=sensitivity,
                    sensitivity_source=sensitivity_source,
                    wrapped_dek=wrapped_dek,
                    ingested_at=promoted_at,
                    ingest_run_id=run_id,
                    dataset_id=f"explorer-upload:{manifest['bucket']}",
                    kek_version=kek_version if is_high else None,
                )
            )
            s3.delete_object(Bucket=staging_bucket, Key=_object_key(upload_id))
            s3.delete_object(Bucket=staging_bucket, Key=_manifest_key(upload_id))

            known.add(claimed_sha256)
            summary["written_high" if is_high else "written_normal"] += 1
            summary["bytes_promoted"] += actual_size
        except Exception as exc:  # noqa: BLE001 - property 3: one bad upload, not the whole run
            summary["failed"].append({"upload_id": upload_id, "error": f"{type(exc).__name__}: {exc}"})
            continue

    if summary["failed"]:
        return finish(catalog.RUN_STATUS_PARTIAL)
    return finish(catalog.RUN_STATUS_SUCCESS)


# --------------------------------------------------------------------------
# Entrypoint — env + compose wiring, mirroring lake_ingest.py's.
# --------------------------------------------------------------------------


def _connect_lake(bucket: str, endpoint: str, region: str, dsn: str):
    """Attach the DuckLake catalog over Postgres with Garage as the data path.
    Identical to `lake_ingest.py::_connect_lake`; duplicated for the same
    reason as `_kind_for` — a leading-underscore helper is not an export."""
    import duckdb

    con = duckdb.connect()
    for extension in ("httpfs", "postgres", "ducklake"):
        con.execute(f"LOAD {extension}")
    con.execute(
        f"""
        CREATE OR REPLACE SECRET garage (
            TYPE s3, KEY_ID '{os.environ["AWS_ACCESS_KEY_ID"]}',
            SECRET '{os.environ["AWS_SECRET_ACCESS_KEY"]}',
            ENDPOINT '{endpoint}', REGION '{region}', URL_STYLE 'path', USE_SSL false
        )
        """
    )
    con.execute(
        f"ATTACH 'ducklake:postgres:{dsn}' AS lake "
        f"(DATA_PATH 's3://{bucket}/bronze/', DATA_INLINING_ROW_LIMIT 0)"
    )
    con.execute("USE lake")
    return con


def _report(summary: dict[str, Any]) -> None:
    label = "DRY RUN — nothing written" if summary["dry_run"] else f"run {summary['run_id']}"
    print(f"{label}: {summary['status']}")
    print(f"  staged uploads seen  {summary['uploads_seen']}")
    print(f"  promoted high        {summary['written_high']}")
    print(f"  promoted normal      {summary['written_normal']}")
    print(f"  skipped (known)      {summary['skipped']}")
    print(f"  bytes promoted       {summary['bytes_promoted']}")
    if summary["dry_run"]:
        print("  (skip counts assume an empty catalog; a dry run reads no catalog)")
    for failure in summary["failed"]:
        print(f"  [FAILED] {failure['upload_id']}: {failure['error']}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Promote verified staged uploads from the staging bucket into bronze.",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="verify and report what WOULD be promoted, writing nothing and deleting nothing.",
    )
    args = parser.parse_args(sys.argv[1:] if argv is None else argv)

    kek_version = int(os.environ.get("LAKE_KEK_VERSION", str(DEFAULT_KEK_VERSION)))
    kek = load_kek_from_env(expected_fingerprint=os.environ.get(ENV_KEK_FINGERPRINT) or None)
    spool_dir = os.environ.get("LAKE_SPOOL_DIR", "/scratch-spool")

    import boto3

    bucket = os.environ["LAKE_S3_BUCKET"]
    endpoint = os.environ["LAKE_S3_ENDPOINT"]
    region = os.environ["LAKE_S3_REGION"]
    staging_bucket = os.environ["LAKE_S3_STAGING_BUCKET"]
    s3 = boto3.client(
        "s3", endpoint_url=f"http://{endpoint}",
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=region,
    )

    if args.dry_run:
        summary = promote(
            s3=s3, staging_bucket=staging_bucket, bucket=bucket, store=_NullStore(),
            kek=kek, kek_version=kek_version, spool_dir=spool_dir, dry_run=True,
        )
    else:
        con = _connect_lake(bucket, endpoint, region, os.environ["LAKE_CATALOG_DSN"])
        summary = promote(
            s3=s3, staging_bucket=staging_bucket, bucket=bucket,
            store=DuckDBCatalogStore(con), kek=kek, kek_version=kek_version, spool_dir=spool_dir,
        )

    _report(summary)
    return 0 if summary["status"] == catalog.RUN_STATUS_SUCCESS else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MissingKekError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        raise SystemExit(3)
    except CatalogSchemaError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        raise SystemExit(4)
