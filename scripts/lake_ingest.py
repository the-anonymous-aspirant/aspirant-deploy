"""Load REAL records into the lake: manifest in, encrypted blobs + catalog rows out.

DATA_LAKE_DESIGN.md §2 (bronze blobs + blob catalog), §8.6 (connector ledger),
§9 (layer 2 envelope encryption). Task **#4271** (`#4238-B1`), layer 1 of the
phase-1 real-data epic #4238.

Why this exists
---------------
`scripts/lake_skeleton_fixtures.py` is the *synthetic* loader: it hand-authors
its blobs in Python literals and is explicitly throwaway. It was never a path
for real bytes and must not become one — the moment it grew a `--real` flag,
the guardrail that makes it obviously-fake (§11.0) would be a flag away from
being off.

So this is a second, separate writer. It shares the two things that must not
fork — the catalog contract (`scripts/lake/catalog.py`, #4270) and the envelope
crypto (`scripts/kek/`, #4133/#4134) — and owns the three things the synthetic
loader never had to face: a source it did not author, a run that can die
halfway, and data that cannot be re-created if it is lost.

The three properties worth reading the code for
-----------------------------------------------
**1. Fail closed, twice.** Sensitivity comes from `catalog.resolve_sensitivity`,
which resolves anything it cannot confidently read as ``normal`` to ``high``. A
``high`` blob is envelope-encrypted before it reaches Garage, and if no KEK is
loaded the run **refuses** — first in a pre-flight pass over the whole manifest,
before a single byte is PUT, and again at the write itself. The pre-flight is
the one that matters operationally: a run that aborts on record 4,000 of 10,000
has already written 3,999 objects the operator now has to reason about, and
"the KEK was not set" is knowable before any of them.

**2. The catalog row is the commit marker.** For each record the object is PUT
*then* the `asset_inventory` row is written, and re-runs skip on the presence of
the row. Ordered the other way, a crash between the two would leave a row
promising an object that is not there — a silent hole a reader only discovers
years later. Ordered this way, a crash leaves an orphan object that the next run
overwrites with the identical key and a row that matches it. Objects are
content-addressed, so the re-PUT is idempotent for ``normal`` data and, for
``high`` data, replaces one valid ciphertext with another valid ciphertext whose
wrapped DEK is written in the same iteration.

That last point is why a re-run must skip on the row rather than blindly re-PUT:
re-encrypting a ``high`` blob mints a fresh DEK, so the *old* row's `wrapped_dek`
would no longer open the *new* object. Overwriting a good object with a good
object is still data loss if the catalog is left pointing at the wrong key.

**3. One bad record does not lose the other ninety-nine.** An unreadable file is
counted, reported, and stepped over; the run finishes and lands in the ledger as
``partial``. What is NOT tolerated is a *systemic* refusal — no KEK — which
aborts, because retrying it 10,000 times produces 10,000 identical failures and
no data.

Idempotence keys on `sha256`, globally
--------------------------------------
§2 defines `asset_inventory` as one row per content-addressed bronze blob, so
"have I already loaded this?" is a question about the blob, not about the blob
*within this dataset*. The consequence is worth stating plainly rather than
discovering: a byte-identical file present in two datasets is stored once and
catalogued once, under whichever dataset loaded it first; the second run counts
it as a skip. That follows the existing §2 contract — de-duplication is the
point of content-addressing — but it does mean `dataset_id` answers "which load
first brought these bytes in", not "every dataset that contains them".

Usage
-----
    python scripts/lake_ingest.py path/to/manifest.json [--dry-run]

    scripts/lake-skeleton.sh ingest path/to/manifest.json   # via the container

The manifest schema and the failure taxonomy are documented in
`docs/data-lake-design/REAL_DATA_INGEST.md`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import mimetypes
import os
import sys
import time
import uuid
from datetime import datetime, timezone

# The envelope machinery (#4133 format, #4134 storage gate + fail-closed loader)
# and the catalog contract (#4270) live beside this script — on disk under
# scripts/, and in the client container mounted at /work/kek and /work/lake.
# Imported, never re-derived: this module contains no cryptography and no DDL of
# its own, and the moment it grows either, the two writers have forked.
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "kek"))
sys.path.insert(0, os.path.join(_HERE, "lake"))

from envelope_store import storage_body_and_wrapped_dek  # noqa: E402
from kek_loader import ENV_KEK_FINGERPRINT, ENV_KEK_HEX, load_kek_from_env  # noqa: E402

import catalog  # noqa: E402

#: Recorded in every `ingest_runs` row. Bump on a change to what the runner
#: writes — a reader years from now needs to know which code produced a row,
#: and "look at the git log" does not survive the repo.
RUNNER_VERSION = "lake-ingest-1.0.0"

#: Which KEK version wraps DEKs minted by this run. The wrapped-DEK header
#: records it too (that copy is the authoritative one, per #4270); the column is
#: the queryable duplicate.
DEFAULT_KEK_VERSION = 1

#: §2's content-addressed bronze layout. Two levels of prefix so that no single
#: listing prefix grows unbounded once the lake holds hundreds of thousands of
#: blobs.
BLOB_PREFIX = "bronze/blobs/sha256"


class ManifestError(ValueError):
    """The manifest is not loadable or does not describe a loadable dataset.

    Raised before any write. A malformed manifest is a mistake to fix, not a
    partial load to reason about.
    """


class CatalogSchemaError(RuntimeError):
    """The catalog's tables do not match the contract this runner writes.

    Raised by `DuckDBCatalogStore.ensure_tables` before the run starts, so a
    catalog left on an older schema stops the ingest at the door instead of
    after it has already PUT objects it cannot then record.
    """


class MissingKekError(RuntimeError):
    """A `high` record must be written and no KEK is loaded — the §9 refusal.

    Deliberately NOT a per-record failure. See the module docstring: a systemic
    refusal aborts the run, because continuing produces one failure per record
    and no data.
    """


# --------------------------------------------------------------------------
# Manifest — what to load, and what the operator declared about it.
# --------------------------------------------------------------------------


def _kind_for(mime: str) -> str:
    """A coarse `kind` for a record that did not declare one.

    Deliberately coarse. `kind` drives which silver table a later enrichment
    step will populate, and guessing finely from a MIME type produces confident
    wrong answers; an honest ``blob`` is better than a wrong ``document``.
    """
    if mime.startswith("image/"):
        return "image"
    if mime.startswith("audio/"):
        return "audio"
    if mime.startswith("video/"):
        return "video"
    if mime.startswith("text/") or mime in ("application/pdf", "application/msword"):
        return "document"
    return "blob"


def load_manifest(path: str) -> dict:
    """Read and validate a source manifest; return it with records normalised.

    Validation is strict and happens up front, because every check here is one
    the runner would otherwise discover mid-load — and a manifest typo found on
    record 6,000 costs the operator a partial lake, while the same typo found
    before the first PUT costs them an edit.

    Record paths resolve relative to the manifest's own directory unless
    absolute, so a manifest and the tree it describes can be moved together.
    """
    try:
        with open(path, "rb") as handle:
            raw = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"cannot read manifest {path}: {exc}") from exc

    if not isinstance(raw, dict):
        raise ManifestError(f"manifest {path} must be a JSON object, got {type(raw).__name__}")

    for required in ("dataset_id", "source", "records"):
        if not raw.get(required):
            raise ManifestError(
                f"manifest {path} is missing required field {required!r}. "
                "dataset_id joins the load back to the operator's #4238-A1 intake "
                "record; source names it in the run ledger; records is the work."
            )

    if not isinstance(raw["records"], list):
        raise ManifestError(f"manifest {path}: 'records' must be a list")

    root = raw.get("root") or os.path.dirname(os.path.abspath(path))
    normalised = []
    for index, record in enumerate(raw["records"]):
        if not isinstance(record, dict) or not record.get("path"):
            raise ManifestError(
                f"manifest {path}: record {index} has no 'path'. Every record names "
                "the file whose bytes are loaded; there is no inline-payload form."
            )
        source_path = record["path"]
        resolved = source_path if os.path.isabs(source_path) else os.path.join(root, source_path)
        mime = record.get("mime") or mimetypes.guess_type(source_path)[0] or "application/octet-stream"
        normalised.append(
            {
                # What the catalog records as provenance: the path as the
                # operator declared it, not the (possibly container-local)
                # path this process happened to open.
                "source_path": source_path,
                "resolved_path": resolved,
                "mime": mime,
                "kind": record.get("kind") or _kind_for(mime),
                # Passed through untouched — resolve_sensitivity owns the
                # interpretation, including of a missing value.
                "declared_sensitivity": record.get("sensitivity"),
            }
        )

    return {
        "dataset_id": raw["dataset_id"],
        "source": raw["source"],
        "retention_class": raw.get("retention_class") or catalog.RETENTION_KEEP_FOREVER,
        "jurisdiction": raw.get("jurisdiction") or catalog.JURISDICTION_EU,
        "records": normalised,
    }


def manifest_needs_kek(manifest: dict) -> bool:
    """Would loading this manifest write at least one `high` blob?

    Answerable without opening a single file, because sensitivity comes from the
    declaration and not from the bytes. That is what makes the pre-flight
    refusal possible — see the module docstring, property 1.
    """
    return any(
        catalog.resolve_sensitivity(record["declared_sensitivity"])[0] == catalog.SENSITIVITY_HIGH
        for record in manifest["records"]
    )


# --------------------------------------------------------------------------
# Catalog store — the DuckDB/DuckLake side, behind a seam the tests can drive.
# --------------------------------------------------------------------------


class DuckDBCatalogStore:
    """Append-only writer for `asset_inventory` and `ingest_runs`.

    Takes a connection rather than making one, so the same class serves the real
    path (a DuckLake-attached connection over Postgres + Garage) and the test
    path (plain in-memory DuckDB). The tests therefore exercise the real SQL and
    the real DDL from `catalog.py` rather than a mock that agrees with itself.

    `CREATE TABLE IF NOT EXISTS`, never `DROP` — the opposite of the synthetic
    loader, which replaces its tables on every seed. A real load appends to a
    catalog that already holds rows it did not write.

    But `IF NOT EXISTS` alone is a trap, and this is how it was found (#4271
    dogfood, 2026-08-25): the live skeleton catalog still carried a 7-column
    `ingest_runs` and a 9-column `asset_inventory` — the schema from before
    #4134 and #4270 widened them. `IF NOT EXISTS` silently bound to those stale
    tables, the run did its whole pre-flight and encrypt pass, and then died on
    the last statement with

        Binder Error: table ingest_runs has 7 columns but 12 values were supplied

    after a `high` blob had already been PUT. So `ensure_tables` verifies the
    columns of a table it did not create, and refuses up front when they do not
    match the contract. A catalog this runner cannot write is a reason not to
    start, not a reason to fail on the last line.
    """

    def __init__(self, con):
        self.con = con

    def _existing_columns(self, table: str) -> list[str] | None:
        """Column names of `table` in declared order, or None if absent."""
        rows = self.con.execute(
            "SELECT column_name FROM information_schema.columns "
            "WHERE table_name = ? ORDER BY ordinal_position",
            [table],
        ).fetchall()
        return [r[0] for r in rows] or None

    def _ensure_table(self, table: str, columns_ddl: str, fields: tuple) -> None:
        existing = self._existing_columns(table)
        if existing is None:
            self.con.execute(f"CREATE TABLE {table} ({columns_ddl})")
            return
        if tuple(existing) == tuple(fields):
            return
        missing = [f for f in fields if f not in existing]
        extra = [c for c in existing if c not in fields]
        raise CatalogSchemaError(
            f"the catalog's '{table}' does not match the contract in scripts/lake/catalog.py: "
            f"it has {len(existing)} column(s), the contract declares {len(fields)}"
            + (f"; missing {missing}" if missing else "")
            + (f"; unexpected {extra}" if extra else "")
            + (
                "; same columns in a different order" if not missing and not extra else ""
            )
            + ". This catalog predates the current contract — re-seed the skeleton "
            "(`lake-skeleton.sh seed`, which replaces its tables) or migrate the table "
            "before ingesting. Refusing up front rather than failing on the INSERT after "
            "objects have already been written."
        )

    def ensure_tables(self) -> None:
        self._ensure_table(
            "asset_inventory", catalog.ASSET_INVENTORY_COLUMNS, catalog.ASSET_INVENTORY_FIELDS
        )
        self._ensure_table("ingest_runs", catalog.INGEST_RUNS_COLUMNS, catalog.INGEST_RUNS_FIELDS)

    def known_sha256(self) -> set:
        """Every blob already catalogued — the skip set for a re-run.

        Read once into memory rather than point-queried per record: DuckDB has
        no index here, so a per-record `WHERE sha256 = ?` is a full scan each
        time, which turns a re-run into O(records x rows). At 64 chars a digest,
        a million blobs is ~70MB — acceptable now, and the line to revisit if
        the lake outgrows it.
        """
        return {row[0] for row in self.con.execute("SELECT sha256 FROM asset_inventory").fetchall()}

    def add_asset(self, row: tuple) -> None:
        placeholders = ", ".join("?" for _ in catalog.ASSET_INVENTORY_FIELDS)
        self.con.execute(f"INSERT INTO asset_inventory VALUES ({placeholders})", list(row))

    def add_run(self, row: tuple) -> None:
        placeholders = ", ".join("?" for _ in catalog.INGEST_RUNS_FIELDS)
        self.con.execute(f"INSERT INTO ingest_runs VALUES ({placeholders})", list(row))


# --------------------------------------------------------------------------
# The run.
# --------------------------------------------------------------------------


def new_run_id(now: datetime) -> str:
    """A run id that sorts by time and cannot collide with a concurrent run."""
    return f"INGEST-{now.strftime('%Y%m%dT%H%M%SZ')}-{uuid.uuid4().hex[:8]}"


def _blob_key(digest: str) -> str:
    return f"{BLOB_PREFIX}/{digest[:2]}/{digest[2:4]}/{digest}"


def ingest(
    manifest: dict,
    *,
    s3,
    bucket: str,
    store,
    kek: bytes | None = None,
    kek_version: int = DEFAULT_KEK_VERSION,
    now: datetime | None = None,
    run_id: str | None = None,
    dry_run: bool = False,
) -> dict:
    """Load every record of `manifest`, and write the run to the ledger.

    Returns a summary dict (the same numbers the ledger row carries, plus the
    per-record detail the ledger has no column for). Raises `MissingKekError`
    *after* writing a ``failed`` ledger row — a run that refused must be visible
    in the ledger, because "no run row" and "a run that declined to write
    unencrypted data" are very different facts and the operator reads only one
    surface.

    `now` and `run_id` are injectable so a test can assert on exact values; the
    defaults are the real clock and a fresh id.
    """
    now = now or datetime.now(timezone.utc)
    run_id = run_id or new_run_id(now)
    ingested_at = now.strftime("%Y-%m-%d %H:%M:%S")
    started = time.monotonic()

    store.ensure_tables()
    known = store.known_sha256()

    summary = {
        "run_id": run_id,
        "dataset_id": manifest["dataset_id"],
        "files_seen": len(manifest["records"]),
        "written_high": 0,
        "written_normal": 0,
        "skipped": 0,
        "failed": [],
        "bytes_ingested": 0,
        "dry_run": dry_run,
    }

    def finish(status: str) -> dict:
        """Write the ledger row and stamp the summary with the outcome."""
        summary["status"] = status
        summary["duration_seconds"] = round(time.monotonic() - started, 3)
        if not dry_run:
            store.add_run(
                catalog.run_row(
                    run_id=run_id,
                    source=manifest["source"],
                    started_on=ingested_at,
                    duration_seconds=summary["duration_seconds"],
                    files_seen=summary["files_seen"],
                    bytes_ingested=summary["bytes_ingested"],
                    status=status,
                    dataset_id=manifest["dataset_id"],
                    runner_version=RUNNER_VERSION,
                    # Only a run that actually wrapped a DEK names a KEK. A run
                    # that wrote nothing high has no key to record, and claiming
                    # one would assert a dependency it does not have.
                    kek_version=kek_version if summary["written_high"] else None,
                    objects_high=summary["written_high"],
                    objects_normal=summary["written_normal"],
                )
            )
        return summary

    # --- pre-flight: refuse the whole run before writing anything ----------
    #
    # Not merely an early copy of the in-loop guard. Under the fail-closed
    # intake rule an *undeclared* record is high, so a manifest with no
    # sensitivity column at all needs a KEK for every line — and finding that
    # out on line 1 costs an edit, while finding it out on line 4,000 costs a
    # half-loaded lake.
    if kek is None and manifest_needs_kek(manifest):
        finish(catalog.RUN_STATUS_FAILED)
        raise MissingKekError(
            f"refusing to load dataset {manifest['dataset_id']}: it contains at least one "
            f"sensitivity=high record (declared, or defaulted under the fail-closed intake "
            f"rule) and no KEK is loaded. Set {ENV_KEK_HEX} to the off-cell grouped hex "
            "(never on disk). Fail-closed per DATA_LAKE_DESIGN.md §9 layer 2. "
            f"Nothing was written; run {run_id} is in the ledger as failed."
        )

    for record in manifest["records"]:
        try:
            with open(record["resolved_path"], "rb") as handle:
                payload = handle.read()
        except OSError as exc:
            # One unreadable file does not lose the other ninety-nine. It is
            # recorded by source_path so the operator can find it afterwards,
            # which is the whole reason the run ends `partial` rather than
            # `success`.
            summary["failed"].append({"source_path": record["source_path"], "error": str(exc)})
            continue

        digest = hashlib.sha256(payload).hexdigest()
        if digest in known:
            # Already catalogued — by an earlier run, or by an earlier record of
            # this same manifest. Skipping is what makes a partial load
            # resumable; see the module docstring, property 2.
            summary["skipped"] += 1
            continue

        sensitivity, sensitivity_source = catalog.resolve_sensitivity(record["declared_sensitivity"])
        is_high = sensitivity == catalog.SENSITIVITY_HIGH

        # Belt and braces over the pre-flight. The pre-flight reads the
        # manifest's declarations; this reads the resolved decision for the
        # record actually in hand, so no future refactor of the former can
        # quietly let a high blob past the latter.
        if is_high and kek is None:
            finish(catalog.RUN_STATUS_FAILED)
            raise MissingKekError(
                f"refusing to write sensitivity=high blob {record['source_path']} with no KEK "
                "loaded (DATA_LAKE_DESIGN.md §9 layer 2)"
            )

        if dry_run:
            summary["written_high" if is_high else "written_normal"] += 1
            summary["bytes_ingested"] += len(payload)
            known.add(digest)
            continue

        stored_body, wrapped_dek = storage_body_and_wrapped_dek(
            payload, sensitivity, kek if is_high else b"", kek_version
        )
        key = _blob_key(digest)

        # PUT first, row second. The row is the commit marker — see the module
        # docstring, property 2. A crash between the two leaves an orphan object
        # that the next run overwrites, not a row pointing at nothing.
        s3.put_object(Bucket=bucket, Key=key, Body=stored_body)
        store.add_asset(
            catalog.asset_row(
                # The content address and size are of the PLAINTEXT: a blob's
                # identity must not change when it is encrypted, or the silver
                # joins break and the read path cannot check what it decrypted.
                sha256=digest,
                object_key=key,
                source_path=record["source_path"],
                mime=record["mime"],
                size_bytes=len(payload),
                kind=record["kind"],
                sensitivity=sensitivity,
                sensitivity_source=sensitivity_source,
                wrapped_dek=wrapped_dek,
                ingested_at=ingested_at,
                ingest_run_id=run_id,
                dataset_id=manifest["dataset_id"],
                retention_class=manifest["retention_class"],
                jurisdiction=manifest["jurisdiction"],
                kek_version=kek_version if is_high else None,
            )
        )

        known.add(digest)
        summary["written_high" if is_high else "written_normal"] += 1
        summary["bytes_ingested"] += len(payload)

    if summary["failed"]:
        # Some records did not load. `partial` even when zero records succeeded:
        # the run did run, and the ledger's `failed` is reserved for a run that
        # refused outright, which is a different thing to investigate.
        return finish(catalog.RUN_STATUS_PARTIAL)
    return finish(catalog.RUN_STATUS_SUCCESS)


# --------------------------------------------------------------------------
# Entrypoint — env + compose wiring, mirroring the fixtures loader's.
# --------------------------------------------------------------------------


def _connect_lake(bucket: str, endpoint: str, region: str, dsn: str):
    """Attach the DuckLake catalog over Postgres with Garage as the data path."""
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
    # DATA_INLINING_ROW_LIMIT 0 for the reason docs/LAKE_SKELETON.md gives:
    # without it DuckLake keeps small writes as rows inside the catalog database
    # instead of parquet in the object store, which would route real data around
    # §9's encryption entirely.
    con.execute(
        f"ATTACH 'ducklake:postgres:{dsn}' AS lake "
        f"(DATA_PATH 's3://{bucket}/bronze/', DATA_INLINING_ROW_LIMIT 0)"
    )
    con.execute("USE lake")
    return con


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Load real records into the lake from a source manifest.",
    )
    parser.add_argument("manifest", help="path to the source manifest (JSON)")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="resolve the manifest and report what WOULD be loaded, writing nothing. "
        "Reads every record (so an unreadable file is reported) but issues no PUT "
        "and no catalog row.",
    )
    args = parser.parse_args(argv)

    try:
        manifest = load_manifest(args.manifest)
    except ManifestError as exc:
        print(f"manifest error: {exc}", file=sys.stderr)
        return 2

    kek_version = int(os.environ.get("LAKE_KEK_VERSION", str(DEFAULT_KEK_VERSION)))

    # Env-only KEK load: this runs non-interactively under compose, so there is
    # no TTY to prompt on. The launcher passes the off-cell hex through the
    # one-shot LAKE_KEK_HEX and does not persist it. `None` here is not an
    # error yet — `ingest`'s pre-flight decides, because a manifest of purely
    # `normal` records legitimately needs no key.
    kek = load_kek_from_env(expected_fingerprint=os.environ.get(ENV_KEK_FINGERPRINT) or None)

    if args.dry_run:
        summary = ingest(
            manifest, s3=None, bucket="", store=_NullStore(), kek=kek,
            kek_version=kek_version, dry_run=True,
        )
    else:
        import boto3

        bucket = os.environ["LAKE_S3_BUCKET"]
        endpoint = os.environ["LAKE_S3_ENDPOINT"]
        region = os.environ["LAKE_S3_REGION"]
        s3 = boto3.client(
            "s3",
            endpoint_url=f"http://{endpoint}",
            aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
            aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
            region_name=region,
        )
        con = _connect_lake(bucket, endpoint, region, os.environ["LAKE_CATALOG_DSN"])
        summary = ingest(
            manifest, s3=s3, bucket=bucket, store=DuckDBCatalogStore(con), kek=kek,
            kek_version=kek_version,
        )

    _report(summary)
    # A `partial` run exits non-zero: some records did not load, and a caller
    # that only checks the exit code must not read that as a clean load.
    return 0 if summary["status"] == catalog.RUN_STATUS_SUCCESS else 1


class _NullStore:
    """Catalog seam for `--dry-run`: answers the skip question, writes nothing.

    An empty skip set is the honest answer here, not a convenient one: a dry run
    that connected to the catalog to report accurate skips would need the
    catalog credentials, and the point of the dry run is to be safe to hand to
    someone checking a manifest. It therefore reports what a load into an EMPTY
    catalog would do, which is stated in the output rather than left to be
    inferred.
    """

    def ensure_tables(self) -> None:
        pass

    def known_sha256(self) -> set:
        return set()

    def add_asset(self, row) -> None:  # pragma: no cover - never called
        raise AssertionError("dry run must not write asset rows")

    def add_run(self, row) -> None:  # pragma: no cover - never called
        raise AssertionError("dry run must not write run rows")


def _report(summary: dict) -> None:
    label = "DRY RUN — nothing written" if summary["dry_run"] else f"run {summary['run_id']}"
    print(f"{label}: {summary['status']}")
    print(f"  dataset          {summary['dataset_id']}")
    print(f"  records seen     {summary['files_seen']}")
    print(f"  written high     {summary['written_high']}")
    print(f"  written normal   {summary['written_normal']}")
    print(f"  skipped (known)  {summary['skipped']}")
    print(f"  bytes ingested   {summary['bytes_ingested']}")
    if summary["dry_run"]:
        print("  (skip counts assume an empty catalog; a dry run reads no catalog)")
    for failure in summary["failed"]:
        print(f"  [FAILED] {failure['source_path']}: {failure['error']}", file=sys.stderr)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MissingKekError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        raise SystemExit(3)
    except CatalogSchemaError as exc:
        print(f"REFUSED: {exc}", file=sys.stderr)
        raise SystemExit(4)
