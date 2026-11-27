"""Tests for scripts/lake/skeleton_content.py (system_3 #12521).

Drives each content check against a real in-memory DuckDB built from the
catalog contract's own DDL, in the three states a lake can be in: fixtures
only, fixtures beside real rows (the cell's state when #12521 was filed), and
real rows only. Every value is invented; the "real" rows are synthetic stand-ins
that simply do not carry the fixtures' dataset id.

Run in the lake client image's pinned DuckDB: tests/lake_skeleton_content_unit.sh.
"""

import hashlib
import os
import sys

import duckdb

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "lake"))
import catalog  # noqa: E402
import skeleton_content as sc  # noqa: E402

AOBJ = b"AOBJ"
FIX = catalog.SYNTHETIC_DATASET_ID
REAL = "intake-2026-11-probe"
MARKERS = ("SYNTHETIC", "FAKE-", "synthetic", "fake-", "2999")
ALLOWED = {"normal", "high", "document", "application/pdf", "declared", "defaulted"}

failures = []


def expect(name, cond, detail=""):
    print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        failures.append(name)


class Store:
    """The blob store: key -> bytes, recording how much of each was read."""

    def __init__(self):
        self.blobs, self.reads = {}, []

    def read(self, key, nbytes):
        self.reads.append((key, nbytes))
        body = self.blobs[key]
        return body[:nbytes] if nbytes else body


def lake():
    con = duckdb.connect()
    con.execute("ATTACH ':memory:' AS lake")
    con.execute("USE lake")
    con.execute(f"CREATE TABLE asset_inventory ({catalog.ASSET_INVENTORY_COLUMNS})")
    con.execute(f"CREATE TABLE ingest_runs ({catalog.INGEST_RUNS_COLUMNS})")
    return con, Store()


def add(con, store, *, dataset, sensitivity="normal", year=2999, path="SYNTHETIC — note.txt",
        body=b"SYNTHETIC body", encrypted=False, corrupt=False, key_digest=None):
    digest = hashlib.sha256(body).hexdigest()
    key = f"bronze/blobs/sha256/{digest[:2]}/{digest[2:4]}/{key_digest or digest}"
    stored = (AOBJ + b"\x01" + b"ciphertext" if encrypted else body)
    if corrupt:
        stored = (b"XXXX" + stored[4:]) if encrypted else stored + b"!"
    store.blobs[key] = stored
    con.execute(
        "INSERT INTO asset_inventory (sha256, object_key, source_path, mime, size_bytes, kind, "
        "sensitivity, wrapped_dek, ingested_at, dataset_id) VALUES (?, ?, ?, 'application/pdf', ?, "
        "'document', ?, ?, make_timestamp(?, 1, 1, 0, 0, 0), ?)",
        [digest, key, path, len(body), sensitivity, "FAKE-WDEK" if encrypted else None, year, dataset],
    )
    con.execute("INSERT INTO ingest_runs (run_id, dataset_id) VALUES (?, ?)", [f"FAKE-RUN-{key[-6:]}", dataset])


def fixtures(con, store):
    add(con, store, dataset=FIX, body=b"SYNTHETIC one")
    add(con, store, dataset=FIX, body=b"SYNTHETIC two")
    add(con, store, dataset=FIX, sensitivity="high", body=b"SYNTHETIC three", encrypted=True)


def guard(con):
    return sc.self_labelling(con, FIX, ["asset_inventory", "ingest_runs"], MARKERS, ALLOWED)


print("fixtures only:")
con, store = lake()
fixtures(con, store)
expect("one high fixture row passes", sc.high_fixture_row(con, FIX)[1] == sc.PASS)
expect("fixture dates in 2999 pass", sc.fixture_dates(con, FIX)[1] == sc.PASS)
expect("self-labelling values pass", guard(con)[1] == sc.PASS, guard(con)[2])
add(con, store, dataset=FIX, path="Rechnung Studio Erfunden.pdf", body=b"SYNTHETIC four")
label, status, detail = guard(con)
expect("an unlabelled fixture value still fails closed", status == sc.FAIL, detail)
expect("…and is named, on a fixtures-only lake", "Rechnung Studio Erfunden.pdf" in detail, detail)

print("fixtures beside real rows (the cell's state):")
con, store = lake()
fixtures(con, store)
for i in range(5):
    add(con, store, dataset=REAL, sensitivity="high", year=2026, path=f"probe-upload-{i}.txt",
        body=f"invented upload {i}".encode(), encrypted=True)
for i in range(4):
    add(con, store, dataset=REAL, year=2026, path=f"probe-normal-{i}.pdf", body=f"invented normal {i}".encode())
expect("real high rows do not count against the fixtures' one", sc.high_fixture_row(con, FIX)[1] == sc.PASS,
       sc.high_fixture_row(con, FIX)[2])
expect("real dates do not count against 2999", sc.fixture_dates(con, FIX)[1] == sc.PASS, sc.fixture_dates(con, FIX)[2])
label, status, detail = guard(con)
expect("the guardrail skips", status == sc.SKIP, f"{status}: {detail}")
expect("…saying how many rows are not fixtures", "18 non-fixture row(s)" in detail, detail)
expect("…and prints no value", "probe-" not in detail and "invented" not in detail, detail)
result = sc.content_addressing(con, store.read, AOBJ)
expect("content addressing passes on plaintext and encrypted rows", result[1] == sc.PASS, result[2])
encrypted_keys = {k for k, v in store.blobs.items() if v.startswith(AOBJ)}
expect("an encrypted blob is read for its header only",
       all(n == len(AOBJ) for k, n in store.reads if k in encrypted_keys) and encrypted_keys, store.reads[:2])
expect("a plaintext blob is read whole", all(n is None for k, n in store.reads if k not in encrypted_keys))

print("content addressing refuses:")
for name, kw, want in (
    ("a plaintext blob that does not hash to its key", {"corrupt": True}, "plaintext blob(s) not hashing"),
    ("an encrypted blob without the header", {"corrupt": True, "encrypted": True}, "without the encrypted-object header"),
    ("a key that does not end in the digest", {"key_digest": "f" * 64}, "key(s) not ending in their digest"),
):
    con, store = lake()
    fixtures(con, store)
    add(con, store, dataset=REAL, year=2026, body=b"invented odd one", **kw)
    result = sc.content_addressing(con, store.read, AOBJ)
    expect(name, result[1] == sc.FAIL and want in result[2], result[2])

print("real rows only:")
con, store = lake()
add(con, store, dataset=REAL, sensitivity="high", year=2026, body=b"invented", encrypted=True)
expect("no fixture rows: the high check skips", sc.high_fixture_row(con, FIX)[1] == sc.SKIP)
expect("no fixture rows: the date check skips", sc.fixture_dates(con, FIX)[1] == sc.SKIP)
expect("the guardrail skips", guard(con)[1] == sc.SKIP)

print("a row with no dataset id:")
con, store = lake()
fixtures(con, store)
add(con, store, dataset=None, year=2026, path="probe-unlabelled.pdf", body=b"invented, no dataset")
label, status, detail = guard(con)
expect("counts as not a fixture, so the guardrail skips", status == sc.SKIP and "probe-" not in detail, detail)

print()
if failures:
    print(f"[FAIL] skeleton_content: {len(failures)} failed")
    sys.exit(1)
print("[PASS] skeleton_content: all checks passed")
