"""Drive the staging lister end to end against moto S3 and a real DuckDB.

system_3 #11615 (#11558-D1). What it shows, per security's c71659 (on #11611)
and c71693 (on #11615):

- each staged upload becomes one row, holding exactly the manifest's fields;
- the job reads listings and `manifest.json` objects only, never a payload;
- a run mirrors staging: an upload removed from staging leaves the table;
- an empty staging still stamps `read_at`, with `upload_count = 0`;
- a listing that fails writes nothing, so `read_at` keeps its old value;
- an unreadable manifest is left out, by id, and the rest are written;
- missing credentials write nothing, print one line and exit 2;
- no output line carries a file name;
- `interval_seconds` is the job's own constant.

The catalog here is an in-memory DuckDB holding the same two tables
lake-skeleton.sh creates. The role's grants are proven on the real catalog by
`lake-skeleton.sh verify`, not here. Every fixture is obviously fake.

Run by tests/lake_list_staged_unit.sh, which installs boto3, moto and duckdb.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
from datetime import datetime, timedelta, timezone

import boto3
import duckdb
from moto import mock_aws

_REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO, "scripts"))

import lake_list_staged as job  # noqa: E402

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


# Obviously-fake file names, one of them the shape a medical upload could take.
NAMES = {
    "up-1111": "SYNTHETIC-befund-not-real-11615.pdf",
    "up-2222": "SYNTHETIC holiday photo NOT REAL 11615.jpg",
}


def manifest(upload_id, name, sensitivity="normal"):
    return {
        "upload_id": upload_id,
        "bucket": "medical" if sensitivity == "high" else "photos",
        "sensitivity": sensitivity,
        "source_filename": name,
        "mime": "application/pdf" if name.endswith(".pdf") else "image/jpeg",
        "size_bytes": 1234,
        "upload_time": "2026-11-18T21:30:00Z",
        "claimed_sha256": "0" * 64,
    }


class Recording:
    """The real moto client, with every GetObject key recorded."""

    def __init__(self, client):
        self._c = client
        self.got = []

    def get_object(self, **kw):
        self.got.append(kw["Key"])
        return self._c.get_object(**kw)

    def __getattr__(self, name):
        return getattr(self._c, name)


class FailingList:
    """A client whose listing fails, as Garage being down would."""

    def get_paginator(self, _name):
        raise RuntimeError("listing unavailable: bronze/staging/up-1111/SYNTHETIC-name.pdf")


def fresh_catalog(with_skipped=True):
    """The catalog as `up` leaves it; `with_skipped=False` is one from before #12113."""
    con = duckdb.connect()
    con.execute("ATTACH ':memory:' AS cat")
    con.execute("CREATE SCHEMA cat.public")
    con.execute(
        "CREATE TABLE cat.public.staged_uploads (upload_id TEXT PRIMARY KEY, bucket TEXT NOT NULL, "
        "sensitivity TEXT NOT NULL, source_filename TEXT NOT NULL, mime TEXT NOT NULL, "
        "size_bytes BIGINT NOT NULL, upload_time TIMESTAMPTZ NOT NULL)"
    )
    con.execute(
        "CREATE TABLE cat.public.staged_uploads_read (id SMALLINT PRIMARY KEY CHECK (id = 1), "
        "read_at TIMESTAMPTZ NOT NULL, interval_seconds INTEGER NOT NULL, upload_count INTEGER NOT NULL)"
    )
    if with_skipped:
        # The same statement `up` runs (lake-skeleton.sh): nullable, no default.
        con.execute("ALTER TABLE cat.public.staged_uploads_read ADD COLUMN IF NOT EXISTS skipped_count INTEGER")
    return con


def stage(client, bucket, upload_id, man=None, raw=None):
    client.put_object(Bucket=bucket, Key=f"bronze/staging/{upload_id}/object", Body=b"SYNTHETIC PAYLOAD - NOT REAL")
    body = raw if raw is not None else json.dumps(man).encode()
    client.put_object(Bucket=bucket, Key=f"bronze/staging/{upload_id}/manifest.json", Body=body)


def rows(con):
    return con.execute(
        "SELECT upload_id, bucket, sensitivity, source_filename, mime, size_bytes FROM cat.public.staged_uploads ORDER BY upload_id"
    ).fetchall()


def stamp(con):
    return con.execute("SELECT read_at, interval_seconds, upload_count FROM cat.public.staged_uploads_read WHERE id = 1").fetchone()


def skipped_count(con):
    return con.execute("SELECT skipped_count FROM cat.public.staged_uploads_read WHERE id = 1").fetchone()[0]


@mock_aws
def main():
    raw_client = boto3.client("s3", region_name="us-east-1")
    bucket = "lake-test-staging-11615"
    raw_client.create_bucket(Bucket=bucket)
    s3 = Recording(raw_client)
    con = fresh_catalog()

    # Two staged uploads, one `high`.
    stage(raw_client, bucket, "up-1111", manifest("up-1111", NAMES["up-1111"], "high"))
    stage(raw_client, bucket, "up-2222", manifest("up-2222", NAMES["up-2222"]))
    t1 = datetime(2026, 11, 19, 6, 0, tzinfo=timezone.utc)
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        summary = job.run(s3, bucket, con, "cat.public", now=t1)
    got = rows(con)
    check("two staged uploads give two rows", len(got) == 2, str(got))
    check(
        "each row holds exactly the manifest's fields",
        got == [
            ("up-1111", "medical", "high", NAMES["up-1111"], "application/pdf", 1234),
            ("up-2222", "photos", "normal", NAMES["up-2222"], "image/jpeg", 1234),
        ],
        str(got),
    )
    check("only manifests are fetched, never a payload", all(k.endswith("/manifest.json") for k in s3.got) and len(s3.got) == 2, str(s3.got))
    read_at, interval, count = stamp(con)
    check("read_at is the run's time, with the job's interval and the count", (read_at, interval, count) == (t1, job.INTERVAL_SECONDS, 2), str(stamp(con)))
    check("the interval is 5 minutes", job.INTERVAL_SECONDS == 300)
    check("the summary carries counts and ids only", summary == {"listed": 2, "written": 2, "skipped_ids": []}, str(summary))

    # The run mirrors staging: an upload removed by hand leaves the table.
    raw_client.delete_object(Bucket=bucket, Key="bronze/staging/up-2222/object")
    raw_client.delete_object(Bucket=bucket, Key="bronze/staging/up-2222/manifest.json")
    t2 = t1 + timedelta(minutes=5)
    job.run(s3, bucket, con, "cat.public", now=t2)
    check("a removed upload drops out at the next run", [r[0] for r in rows(con)] == ["up-1111"], str(rows(con)))
    check("the stamp moves to the second run, with count 1", stamp(con)[0] == t2 and stamp(con)[2] == 1, str(stamp(con)))

    # An unreadable manifest is left out by id; the rest are written.
    stage(raw_client, bucket, "up-3333", raw=b"{not json")
    stage(raw_client, bucket, "up-4444", man={**manifest("up-4444", "x.pdf"), "size_bytes": "big"})
    t3 = t2 + timedelta(minutes=5)
    summary = job.run(s3, bucket, con, "cat.public", now=t3)
    check("unreadable and malformed manifests are left out", [r[0] for r in rows(con)] == ["up-1111"], str(rows(con)))
    check("their ids are reported", summary["skipped_ids"] == ["up-3333", "up-4444"], str(summary))
    check("the stamp records how many were left out (c75275)", skipped_count(con) == 2, str(skipped_count(con)))
    raw_client.delete_object(Bucket=bucket, Key="bronze/staging/up-3333/manifest.json")
    raw_client.delete_object(Bucket=bucket, Key="bronze/staging/up-3333/object")
    raw_client.delete_object(Bucket=bucket, Key="bronze/staging/up-4444/manifest.json")
    raw_client.delete_object(Bucket=bucket, Key="bronze/staging/up-4444/object")

    # A failed listing writes nothing: the rows and the stamp stay as they were.
    before_rows, before_stamp = rows(con), stamp(con)
    raised = False
    try:
        job.run(FailingList(), bucket, con, "cat.public", now=t3 + timedelta(minutes=5))
    except RuntimeError:
        raised = True
    check("a failed listing raises before any write", raised)
    check("a failed listing leaves the rows and read_at as they were", rows(con) == before_rows and stamp(con) == before_stamp, str(stamp(con)))

    # An empty staging still stamps read_at, with count 0.
    raw_client.delete_object(Bucket=bucket, Key="bronze/staging/up-1111/object")
    raw_client.delete_object(Bucket=bucket, Key="bronze/staging/up-1111/manifest.json")
    t5 = t3 + timedelta(minutes=10)
    job.run(s3, bucket, con, "cat.public", now=t5)
    check("an empty staging leaves no rows", rows(con) == [], str(rows(con)))
    check("an empty staging still stamps read_at, with count 0", stamp(con)[0] == t5 and stamp(con)[2] == 0, str(stamp(con)))
    check("and a run that left none out records 0 skipped", skipped_count(con) == 0, str(skipped_count(con)))

    # A file name longer than 255 characters is kept to 255.
    long_name = "SYNTHETIC-" + "x" * 300 + ".pdf"
    stage(raw_client, bucket, "up-5555", manifest("up-5555", long_name))
    job.run(s3, bucket, con, "cat.public")
    check("a long file name is kept to 255 characters", len(rows(con)[0][3]) == 255, str(len(rows(con)[0][3])))

    # main(): missing credentials write nothing, say so in one line, exit 2.
    err = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
        code = job.main(env={"LAKE_S3_ENDPOINT": "x", "LAKE_S3_REGION": "garage", "LAKE_S3_STAGING_BUCKET": bucket})
    lines = [line for line in err.getvalue().splitlines() if line.strip()]
    check("missing credentials exit 2", code == 2, str(code))
    check("missing credentials say so in exactly one line", len(lines) == 1 and "refused: not provisioned" in lines[0], str(lines))

    # main(): a listing failure prints its exception TYPE only, never its text
    # (an error can quote a key, and a key holds a file name).
    env = {name: "x" for name in job.REQUIRED_ENV}
    env["LAKE_S3_ENDPOINT"] = "127.0.0.1:9"  # nothing listens: the listing fails
    err = io.StringIO()
    with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
        code = job.main(env=env)
    check("a listing failure exits 1", code == 1, str(code))
    check("a listing failure logs the error's type, not its text", "listing failed (" in err.getvalue() and "SYNTHETIC" not in err.getvalue(), err.getvalue())

    # A stamp an older lister wrote, before `up` added the column, reads NULL
    # ("not recorded"), never 0 (security c75284, condition 2).
    old = fresh_catalog(with_skipped=False)
    old.execute("INSERT INTO cat.public.staged_uploads_read (id, read_at, interval_seconds, upload_count) VALUES (1, ?, 300, 0)", [t1])
    old.execute("ALTER TABLE cat.public.staged_uploads_read ADD COLUMN IF NOT EXISTS skipped_count INTEGER")
    check("an older lister's stamp reads NULL once the column is added, not 0", skipped_count(old) is None, str(skipped_count(old)))

    # The wrong deploy order (c75284, condition 4): a catalog without the column
    # refuses the write. The run raises, and the rows and read_at stay as they
    # were, so the page shows the list as out of date instead of a fresh stamp.
    old = fresh_catalog(with_skipped=False)
    prior = datetime(2026, 11, 19, 5, 0, tzinfo=timezone.utc)
    old.execute("INSERT INTO cat.public.staged_uploads VALUES ('up-0000', 'photos', 'normal', 'SYNTHETIC-old.jpg', 'image/jpeg', 1, ?)", [prior])
    old.execute("INSERT INTO cat.public.staged_uploads_read VALUES (1, ?, 300, 1)", [prior])
    stage(raw_client, bucket, "up-6666", manifest("up-6666", "y.pdf"))
    before_rows, before_stamp = rows(old), stamp(old)
    refused = False
    try:
        job.run(s3, bucket, old, "cat.public", now=t5 + timedelta(minutes=5))
    except Exception:
        refused = True
    check("a catalog without skipped_count refuses the write", refused)
    check("and keeps its rows and read_at as they were", rows(old) == before_rows and stamp(old) == before_stamp, str(stamp(old)))

    # main(), the entry the staging-lister service runs, records the skipped
    # count too (security c75692 on #12113): every case above writes through
    # run(). The S3 client and the catalog attach are swapped for the moto
    # client and an in-memory catalog; everything between them is main()'s own.
    main_bucket = "lake-test-staging-main"
    raw_client.create_bucket(Bucket=main_bucket)
    stage(raw_client, main_bucket, "up-7777", manifest("up-7777", NAMES["up-1111"]))
    stage(raw_client, main_bucket, "up-8888", raw=b"{not json")
    stage(raw_client, main_bucket, "up-9999", man={**manifest("up-9999", "z.pdf"), "size_bytes": "big"})
    cat_con = fresh_catalog()

    class AttachedCatalog:
        """The in-memory catalog, with main()'s LOAD and ATTACH as no-ops."""
        def execute(self, sql, *args):
            if sql.startswith(("LOAD postgres", "ATTACH ")):
                return None
            return cat_con.execute(sql, *args)

    env = {name: "x" for name in job.REQUIRED_ENV}
    env["LAKE_S3_STAGING_BUCKET"] = main_bucket
    real_client, real_connect = boto3.client, duckdb.connect
    boto3.client, duckdb.connect = (lambda *a, **k: raw_client), (lambda *a, **k: AttachedCatalog())
    main_out, main_err = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(main_out), contextlib.redirect_stderr(main_err):
            code = job.main(env=env)
    finally:
        boto3.client, duckdb.connect = real_client, real_connect
    check("main() with two unreadable uploads exits 0", code == 0, f"{code} {main_err.getvalue()}")
    check("main() stamps the count it listed", stamp(cat_con)[2] == 1, str(stamp(cat_con)))
    check("main() stamps the skipped count, not 0 (c75692)", skipped_count(cat_con) == 2, str(skipped_count(cat_con)))
    check("main()'s log names the skipped ids only", "up-8888" in main_out.getvalue() and NAMES["up-1111"] not in main_out.getvalue(), main_out.getvalue())

    # No output of any run above carries a file name.
    logged = out.getvalue() + err.getvalue()
    check("no output carries a file name", not any(n in logged for n in NAMES.values()), logged)

    print(f"\n{PASSED} passed, {FAILED} failed")
    return 1 if FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
