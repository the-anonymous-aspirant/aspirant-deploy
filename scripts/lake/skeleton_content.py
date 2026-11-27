"""The content checks of `lake_skeleton_verify.py`, scoped to what they test.

system_3 #12521. The skeleton's content checks were written for phase 0, when
the lake held only the synthetic fixtures. They asserted the fixture set's shape
on *every* row, so a lake that has since received real uploads failed them for
being a lake: more than one `sensitivity=high` row, dates outside 2999, free
text that is not self-labelling, and encrypted blobs whose stored bytes are
ciphertext and so cannot hash to the plaintext digest they are keyed by.

Each check now asks the question it can answer:

* the fixture-shape checks look at the fixture rows only, picked out by
  `catalog.SYNTHETIC_DATASET_ID`;
* content addressing holds for every row, real or fixture, and is checked the
  way each row is stored: a plaintext blob must hash to its key; an encrypted
  one must be keyed by its digest and carry the encrypted-object header (its
  plaintext digest can only be checked by decrypting, which `verify` must
  not do);
* the free-text guardrail scans tables most of which have no `dataset_id`, so
  it cannot tell a fixture value from a real one. On a lake that holds any
  non-fixture row it is skipped, with the reason, and prints no value: a
  verify must not copy operator data out of the lake into its log.

Pure: every function takes a DuckDB connection whose default schema holds the
lake's tables (and, for the guardrail, the `lake.main.<table>` names), and
returns `(label, status, detail)` with status `PASS`, `FAIL` or `SKIP`. The
caller prints and counts. Stdlib only, so the tests need nothing but DuckDB.
"""

from __future__ import annotations

import hashlib

PASS, FAIL, SKIP = "PASS", "FAIL", "SKIP"

#: The two tables `catalog.py` gives a `dataset_id` column.
DATASET_TABLES = ("asset_inventory", "ingest_runs")

FIXTURE_YEAR = 2999


def fixture_rows(con, fixture_id: str) -> int:
    return con.execute(
        "SELECT count(*) FROM asset_inventory WHERE dataset_id = ?", [fixture_id]
    ).fetchone()[0]


def non_fixture_rows(con, fixture_id: str) -> int:
    """Rows in the dataset-carrying tables that are not fixtures.

    A NULL `dataset_id` counts as not a fixture: a row that does not say it is
    synthetic is treated as real.
    """
    return sum(
        con.execute(
            f"SELECT count(*) FROM {table} WHERE dataset_id IS DISTINCT FROM ?",  # noqa: S608 - table is one of two literals
            [fixture_id],
        ).fetchone()[0]
        for table in DATASET_TABLES
    )


def high_fixture_row(con, fixture_id: str):
    """The fixtures carry exactly one `high` row (§2: sensitivity is a column,
    so one row differs only by it, which is the case #2360 must handle)."""
    if not fixture_rows(con, fixture_id):
        return ("A sensitivity=high fixture row exists", SKIP, "the lake holds no fixture rows")
    high = con.execute(
        "SELECT count(*) FROM asset_inventory WHERE sensitivity = 'high' AND dataset_id = ?",
        [fixture_id],
    ).fetchone()[0]
    return (
        "A sensitivity=high fixture row exists",
        PASS if high == 1 else FAIL,
        f"{high} high-sensitivity fixture row(s)",
    )


def fixture_dates(con, fixture_id: str):
    if not fixture_rows(con, fixture_id):
        return (f"Fixture dates are all in {FIXTURE_YEAR}", SKIP, "the lake holds no fixture rows")
    dates = con.execute(
        "SELECT count(*) FROM asset_inventory "
        f"WHERE dataset_id = ? AND date_part('year', ingested_at) <> {FIXTURE_YEAR}",
        [fixture_id],
    ).fetchone()[0]
    return (
        f"Fixture dates are all in {FIXTURE_YEAR}",
        PASS if dates == 0 else FAIL,
        f"{dates} fixture row(s) outside {FIXTURE_YEAR}",
    )


def content_addressing(con, read_blob, aobj_magic: bytes):
    """Every blob, real or fixture, is stored at its own content address.

    `read_blob(key, nbytes)` returns the stored bytes, or only the first
    `nbytes` when it is given. An encrypted object is read for its header only.
    """
    wrong_key, bad_plain, bad_header = 0, 0, 0
    rows = con.execute("SELECT sha256, object_key, wrapped_dek FROM asset_inventory").fetchall()
    for digest, key, wrapped_dek in rows:
        if not key.endswith(digest):
            wrong_key += 1
            continue
        if wrapped_dek is None:
            if hashlib.sha256(read_blob(key, None)).hexdigest() != digest:
                bad_plain += 1
        elif read_blob(key, len(aobj_magic)) != aobj_magic:
            bad_header += 1
    problems = [
        f"{n} {what}"
        for n, what in (
            (wrong_key, "key(s) not ending in their digest"),
            (bad_plain, "plaintext blob(s) not hashing to their key"),
            (bad_header, "encrypted blob(s) without the encrypted-object header"),
        )
        if n
    ]
    plain = sum(1 for r in rows if r[2] is None)
    return (
        "Every blob is stored at its own content address",
        FAIL if problems else PASS,
        "; ".join(problems) if problems
        else f"{plain} plaintext blob(s) hash to their key; {len(rows) - plain} encrypted blob(s) keyed by digest, with the header",
    )


def self_labelling(con, fixture_id: str, tables, markers, allowed):
    """The guardrail that must fail closed on a fixtures-only lake: every
    free-text value in every fixture table names itself as fake."""
    label = "No fixture value could be mistaken for operator data"
    real = non_fixture_rows(con, fixture_id)
    if real:
        return (
            label,
            SKIP,
            f"the lake holds {real} non-fixture row(s) in {' and '.join(DATASET_TABLES)}, and most of the "
            "scanned tables carry no "
            "dataset_id, so a fixture value cannot be told from a real one; no value is printed",
        )
    leaks = []
    for table in tables:
        for col_name, col_type, *_ in con.execute(f"DESCRIBE lake.main.{table}").fetchall():
            if "VARCHAR" not in col_type:
                continue
            for (value,) in con.execute(
                f"SELECT DISTINCT {col_name} FROM lake.main.{table} WHERE {col_name} IS NOT NULL"  # noqa: S608 - names come from DESCRIBE
            ).fetchall():
                v = str(value)
                # Hashes, object keys and month strings are structural, not prose.
                if v in allowed or all(c in "0123456789abcdef" for c in v) or v.startswith("bronze/blobs/"):
                    continue
                if not any(m in v for m in markers):
                    leaks.append(f"{table}.{col_name}={v!r}")
    return (
        label,
        FAIL if leaks else PASS,
        f"{len(leaks)} unlabelled value(s): {leaks[:3]}" if leaks else "every free-text value is self-labelling",
    )
