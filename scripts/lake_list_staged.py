"""List what is waiting in the staging bucket into the catalog, every few minutes.

system_3 #11615 (#11558-D1). Security's rulings: c71659 on #11611 (conditions
1-6) and c71693 on #11615 (the two tables, who creates them, the grants).

Why this exists
---------------
An upload lands in the staging bucket and waits there until an attended
promotion run moves it into bronze. Until then no explorer page can show it:
the explorer reads the catalog, and the catalog knows only promoted files. So
an upload looked lost (system_3 #11558). This job writes a small mirror of
staging into the catalog, `staged_uploads`, one row per staged upload, plus a
one-row `staged_uploads_read` that says when staging was last read and how
often it is read. The explorer's read-only role can see both (D2, #11616).

What it may touch, and nothing else
-----------------------------------
- **Its own Garage key** (`lake-skeleton-staging-lister`, issued by
  lake-skeleton.sh): read on staging only. It never uses the promotion
  runner's key, which can write the whole lake.
- **Listings and each `<upload id>/manifest.json`. Never a payload object**
  (condition 2). A staged `high` upload is unencrypted plaintext; this job has
  no reason to read it.
- **Its own catalog role** (`staging_lister`): `SELECT, INSERT, DELETE` on
  `staged_uploads`, `SELECT, INSERT, UPDATE` on `staged_uploads_read`. The
  catalog owner creates both tables, so the job's role owns neither.

How a run goes
--------------
1. With its key or its DSN missing, it writes nothing, says so in one line and
   exits 2 (condition 5).
2. It lists `bronze/staging/` and reads each manifest. A listing that fails
   ends the run with nothing written, so `read_at` keeps its old value and the
   page shows the list as out of date (c71693).
3. A manifest that cannot be read or is malformed is left out, and its upload
   id is logged. The others are still written: one bad upload should not hide
   the rest.
4. Only then, in ONE transaction: every `staged_uploads` row is deleted, the
   new rows are inserted, and the `staged_uploads_read` row is updated (or
   inserted the first time). An upload promoted or removed by hand drops out
   at the next run.

Logs carry counts and upload ids, never a file name: a staged `high` upload's
name can itself be medical (condition 4). File names reach the catalog only
as bound parameters, never pasted into SQL.

Usage
-----
    scripts/lake-skeleton.sh list-staged      # its own compose service
"""

from __future__ import annotations

import json
import os
import sys
from datetime import datetime, timezone
from typing import Any

# How often the job runs, in seconds. The cron line in system_3's
# cron/crontab.manifest runs it every 5 minutes, and this value is written to
# `staged_uploads_read.interval_seconds` so the page states the real interval
# from one constant (design ruling on #11616).
INTERVAL_SECONDS = 300

STAGING_PREFIX = "bronze/staging/"
MANIFEST_NAME = "manifest.json"
# The manifest's fields this job keeps (c71659 condition 3). Nothing else from
# the manifest reaches the catalog: not the claimed digest, not the object key.
TEXT_FIELDS = ("bucket", "sensitivity", "source_filename", "mime")
FILENAME_LIMIT = 255

ENV_KEY = "LAKE_S3_STAGING_LISTER_ACCESS_KEY"
ENV_SECRET = "LAKE_S3_STAGING_LISTER_SECRET_KEY"
ENV_DSN = "LAKE_CATALOG_STAGING_LISTER_DSN"
REQUIRED_ENV = (ENV_KEY, ENV_SECRET, ENV_DSN, "LAKE_S3_ENDPOINT", "LAKE_S3_REGION", "LAKE_S3_STAGING_BUCKET")

LOG = "staging-lister:"


def manifest_key(upload_id: str) -> str:
    return f"{STAGING_PREFIX}{upload_id}/{MANIFEST_NAME}"


def list_upload_ids(s3, staging_bucket: str) -> list[str]:
    """Every upload id under `bronze/staging/`, sorted. Raises if the listing fails.

    One paginated listing with `Delimiter`, which groups each upload's keys
    into one `CommonPrefixes` entry: no object is read to learn what exists.
    """
    ids = []
    paginator = s3.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=staging_bucket, Prefix=STAGING_PREFIX, Delimiter="/"):
        for entry in page.get("CommonPrefixes") or []:
            upload_id = entry["Prefix"][len(STAGING_PREFIX):].rstrip("/")
            if upload_id:
                ids.append(upload_id)
    return sorted(ids)


def row_from_manifest(upload_id: str, raw: Any) -> dict[str, Any] | None:
    """The catalog row for one upload, or None when the manifest will not do."""
    if not isinstance(raw, dict):
        return None
    row: dict[str, Any] = {"upload_id": upload_id}
    for field in TEXT_FIELDS:
        value = raw.get(field)
        if not isinstance(value, str) or not value:
            return None
        row[field] = value
    row["source_filename"] = row["source_filename"][:FILENAME_LIMIT]
    size = raw.get("size_bytes")
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        return None
    row["size_bytes"] = size
    stamp = raw.get("upload_time")
    if not isinstance(stamp, str):
        return None
    try:
        when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    row["upload_time"] = when
    return row


def read_staging(s3, staging_bucket: str) -> tuple[list[dict[str, Any]], list[str]]:
    """(rows, skipped upload ids). The listing's own failure is NOT caught here."""
    rows, skipped = [], []
    for upload_id in list_upload_ids(s3, staging_bucket):
        try:
            body = s3.get_object(Bucket=staging_bucket, Key=manifest_key(upload_id))["Body"].read()
            raw = json.loads(body)
        except Exception:  # noqa: BLE001 - any read or parse error leaves this upload out
            skipped.append(upload_id)
            continue
        row = row_from_manifest(upload_id, raw)
        if row is None:
            skipped.append(upload_id)
        else:
            rows.append(row)
    return rows, skipped


def write_snapshot(con, schema: str, rows: list[dict[str, Any]], read_at: datetime, skipped_count: int = 0) -> None:
    """Replace `staged_uploads` and stamp `staged_uploads_read`, in one transaction.

    `schema` is the qualified schema the two tables live in: `cat.public` on
    the catalog (a DuckDB postgres attach), anything with the same tables in a
    test. `DELETE`, not `TRUNCATE`: the role is granted DELETE only, and a
    TRUNCATE would take a lock that blocks the explorer's reads (c71693).

    `skipped_count` is how many uploads the listing found but could not read
    (design c75275 on #12113): the explorer counts them as waiting, so a page
    never says nothing is waiting while one sits in staging unlisted.
    """
    con.execute("BEGIN TRANSACTION")
    try:
        con.execute(f"DELETE FROM {schema}.staged_uploads")
        for r in rows:
            con.execute(
                f"INSERT INTO {schema}.staged_uploads "
                "(upload_id, bucket, sensitivity, source_filename, mime, size_bytes, upload_time) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                [r["upload_id"], r["bucket"], r["sensitivity"], r["source_filename"], r["mime"],
                 r["size_bytes"], r["upload_time"]],
            )
        stamped = con.execute(f"SELECT count(*) FROM {schema}.staged_uploads_read WHERE id = 1").fetchone()[0]
        if stamped:
            con.execute(
                f"UPDATE {schema}.staged_uploads_read SET read_at = ?, interval_seconds = ?, upload_count = ?, "
                "skipped_count = ? WHERE id = 1",
                [read_at, INTERVAL_SECONDS, len(rows), skipped_count],
            )
        else:
            con.execute(
                f"INSERT INTO {schema}.staged_uploads_read (id, read_at, interval_seconds, upload_count, skipped_count) "
                "VALUES (1, ?, ?, ?, ?)",
                [read_at, INTERVAL_SECONDS, len(rows), skipped_count],
            )
        con.execute("COMMIT")
    except Exception:
        con.execute("ROLLBACK")
        raise


def run(s3, staging_bucket: str, con, schema: str, now: datetime | None = None) -> dict[str, Any]:
    """One pass: read staging, then write it. Returns counts and ids only."""
    rows, skipped = read_staging(s3, staging_bucket)
    write_snapshot(con, schema, rows, now or datetime.now(timezone.utc), len(skipped))
    return {"listed": len(rows) + len(skipped), "written": len(rows), "skipped_ids": skipped}


def missing_env(env: dict[str, str]) -> list[str]:
    return [name for name in REQUIRED_ENV if not env.get(name)]


def main(env: dict[str, str] | None = None) -> int:
    env = dict(os.environ) if env is None else env
    missing = missing_env(env)
    if missing:
        print(f"{LOG} refused: not provisioned ({', '.join(missing)} unset); wrote nothing", file=sys.stderr)
        return 2

    import boto3
    import duckdb

    s3 = boto3.client(
        "s3", endpoint_url=f"http://{env['LAKE_S3_ENDPOINT']}",
        aws_access_key_id=env[ENV_KEY], aws_secret_access_key=env[ENV_SECRET],
        region_name=env["LAKE_S3_REGION"],
    )
    try:
        rows, skipped = read_staging(s3, env["LAKE_S3_STAGING_BUCKET"])
    except Exception as exc:  # noqa: BLE001 - the error text could name a key; log its type only
        print(f"{LOG} listing failed ({type(exc).__name__}); wrote nothing, read_at keeps its last value", file=sys.stderr)
        return 1

    con = duckdb.connect()
    con.execute("LOAD postgres")
    try:
        con.execute(f"ATTACH '{env[ENV_DSN]}' AS cat (TYPE postgres)")
        write_snapshot(con, "cat.public", rows, datetime.now(timezone.utc))
    except Exception as exc:  # noqa: BLE001 - see above; and never echo the DSN
        print(f"{LOG} catalog write failed ({type(exc).__name__}); nothing committed", file=sys.stderr)
        return 1

    line = f"{LOG} staging read: {len(rows)} upload(s) listed in the catalog"
    if skipped:
        line += f", {len(skipped)} left out with an unreadable manifest: {', '.join(skipped)}"
    print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
