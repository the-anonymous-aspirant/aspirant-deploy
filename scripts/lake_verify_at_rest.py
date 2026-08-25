"""Prove — not assume — that what is on disk in the lake is actually encrypted.

DATA_LAKE_DESIGN.md §9 layer 2. Task **#4299** (`#4273-A1`), layer 2 of the
phase-1 real-data epic #4238.

Why this exists before the real load, not after
-----------------------------------------------
#4238-D1 (the first load of real personal data) is blocked on this harness, and
the ordering is the whole point. Verifying encryption after the fact is not the
same act: the bytes are already written, and a misclassification or a silent
plaintext fallback discovered afterwards cannot be un-written. So the ability to
check has to exist first, and it has to be the kind of check that can fail.

What it checks, and what each check would catch
-----------------------------------------------
Read the numbering as five separate claims, because they fail separately:

  1. every ``sensitivity=high`` row declares an envelope — a non-null
     ``wrapped_dek`` and a non-null ``kek_version``. Catches a row the ingest
     runner classified as high and then catalogued as if it were not.

  2. the object as **stored** begins with the ``AOBJ`` magic. Fetched with a
     plain S3 ``GET``: never through the explorer's read path, which decrypts
     and would therefore render a plaintext write indistinguishable from a
     correctly encrypted one. A harness that reads through the decrypting path
     is checking the decryptor, not the disk.

  3. the reverse claim — nothing readable as plaintext is sitting under a row
     that says ``high``, and no ``normal`` row carries a wrapped DEK. Where this
     fails it names *what* was found in the clear, because "there is a readable
     PDF on disk under a row claiming encryption" is a sentence somebody acts
     on and "check 3 failed" is not.

  4. the ``kek_version`` on the row agrees with the ``WDEK`` header it
     duplicates. #4270 put that column on the row deliberately so that "which
     records are sealed under a key we no longer hold?" is a catalog query
     rather than a full object scan — and because it is a duplicate it can
     drift, which is what this compares.

  5. the wrapped DEK actually unwraps under the KEK in custody. A row encrypted
     under a key nobody holds is not secure, it is lost; #4273 says so in as
     many words. This is the only check that needs key material.

And one that is not in #4273's list
-----------------------------------
``asset_inventory.sha256`` is the digest of the **plaintext**. So a ``high``
row's stored bytes must hash to something *different*, and a ``normal`` row's
must hash to *exactly* that. This is the check that survives an adversary the
magic-byte test does not — a plaintext object with five bytes of forged ``AOBJ``
header in front of it passes check 2 — and it is compared **twice** for a high
row: against the whole stored object, and against the object past the header
length, because prefixing bytes changes the first digest but not the second.
It is the difference between checking a label and checking the bytes.

Running it
----------
Against a live lake, through the compose client profile::

    scripts/lake-skeleton.sh verify-at-rest      # once #4300 wires the verb
    python scripts/lake_verify_at_rest.py        # directly, with the env below

Env: ``LAKE_CATALOG_DSN``, ``LAKE_S3_ENDPOINT``, ``LAKE_S3_BUCKET``,
``LAKE_S3_REGION``, ``AWS_ACCESS_KEY_ID``, ``AWS_SECRET_ACCESS_KEY``, and
optionally ``LAKE_KEK_HEX`` (+ ``LAKE_KEK_FINGERPRINT``) for check 5.

Without a lake at all::

    python scripts/lake_verify_at_rest.py --self-test

which runs the whole verdict engine against in-memory rows with failures
deliberately planted. That is what "prove the harness on synthetic data" has to
mean: not that it once said PASS, but that it goes RED on a plant. A harness
nobody has watched fail is not evidence.

A note on the crypto import
---------------------------
``dek_envelope`` imports ``cryptography`` at module scope, and the pinned client
image predates that dependency (#4290). A harness that cannot run on the image
the cell actually has is not a harness — so the two magics and two header
formats are mirrored here behind an ImportError fallback, the harness reports
which path it took, and ``tests/lake_verify_at_rest_unit.sh`` asserts the mirror
still equals ``dek_envelope``'s values wherever the import succeeds. Duplication
under a drift guard, declared rather than quiet.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "kek"))
sys.path.insert(0, os.path.join(_HERE, "lake"))

import catalog  # noqa: E402  — the sensitivity vocabulary, imported not copied

# --------------------------------------------------------------------------
# Envelope header parsing.
# --------------------------------------------------------------------------

# Mirrors of dek_envelope's format constants, used only when that module cannot
# be imported. Kept adjacent to the import so the two are read together, and
# drift-guarded by tests/lake_verify_at_rest_unit.sh.
_MIRROR_WDEK_MAGIC = b"WDEK"
_MIRROR_AOBJ_MAGIC = b"AOBJ"
_MIRROR_WDEK_HEADER = struct.Struct(">4sBI")  # magic, format version, kek_version
_MIRROR_AOBJ_HEADER = struct.Struct(">4sB")

try:  # pragma: no cover - exercised by both branches in the unit script
    import dek_envelope

    WDEK_MAGIC = dek_envelope.WDEK_MAGIC
    AOBJ_MAGIC = dek_envelope.AOBJ_MAGIC
    _WDEK_HEADER = dek_envelope._WDEK_HEADER
    CRYPTO_AVAILABLE = True
except Exception:  # ImportError, or cryptography missing underneath it
    dek_envelope = None
    WDEK_MAGIC = _MIRROR_WDEK_MAGIC
    AOBJ_MAGIC = _MIRROR_AOBJ_MAGIC
    _WDEK_HEADER = _MIRROR_WDEK_HEADER
    CRYPTO_AVAILABLE = False


# The AOBJ header is `magic + format version`; everything past it is nonce +
# ciphertext + tag. Its length is what the content-address cross-check has to
# skip to catch a plaintext object wearing a forged header.
_AOBJ_HEADER_LEN = _MIRROR_AOBJ_HEADER.size


class HeaderError(ValueError):
    """A blob whose envelope header cannot be read at all."""


def wdek_header_kek_version(wrapped: bytes) -> int:
    """The kek_version recorded inside a wrapped-DEK blob.

    Pure struct parsing — no key material and no crypto library — which is what
    lets check 4 run on an image that cannot import `dek_envelope`.
    """
    if len(wrapped) < _WDEK_HEADER.size:
        raise HeaderError(f"wrapped DEK is {len(wrapped)} bytes, too short for a header")
    magic, _fmt, kek_version = _WDEK_HEADER.unpack(wrapped[: _WDEK_HEADER.size])
    if magic != WDEK_MAGIC:
        raise HeaderError(f"wrapped DEK does not start with {WDEK_MAGIC!r}: {magic!r}")
    return kek_version


# --------------------------------------------------------------------------
# Plaintext sniffing — for naming what was found, not for deciding encryption.
# --------------------------------------------------------------------------

# Signatures of the formats §2 says the lake holds. This list is deliberately
# NOT the thing that decides whether an object is encrypted — the AOBJ check and
# the content-address cross-check do that, and both are exact. This only turns
# "not encrypted" into "a readable PDF", which is the difference between a
# finding somebody acts on and a check number.
_PLAINTEXT_SIGNATURES = (
    (b"%PDF-", "a PDF"),
    (b"\x89PNG\r\n\x1a\n", "a PNG image"),
    (b"\xff\xd8\xff", "a JPEG image"),
    (b"PK\x03\x04", "a zip container (docx/xlsx/odt or an archive)"),
    (b"RIFF", "a RIFF container (wav/avi)"),
    (b"ID3", "an MP3 with ID3 tags"),
    (b"OggS", "an Ogg stream"),
    (b"SQLite format 3\x00", "a SQLite database"),
    (b"<?xml", "an XML document"),
    (b"%!PS", "a PostScript document"),
)


def describe_plaintext(body: bytes) -> str | None:
    """What this object appears to be, in the clear — or None if it is opaque."""
    for signature, description in _PLAINTEXT_SIGNATURES:
        if body.startswith(signature):
            return description

    stripped = body.lstrip()[:1]
    if stripped in (b"{", b"["):
        try:
            json.loads(body)
        except Exception:
            pass
        else:
            return "readable JSON"

    # UTF-8 that decodes cleanly and is mostly printable is text. Checked last
    # and on a bounded prefix: ciphertext decodes as UTF-8 only by accident, and
    # when it does it is not printable.
    sample = body[:512]
    try:
        text = sample.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if text and sum(ch.isprintable() or ch in "\r\n\t" for ch in text) / len(text) > 0.95:
        return "readable text"
    return None


# --------------------------------------------------------------------------
# The verdict engine.
# --------------------------------------------------------------------------

PASS = "PASS"
FAIL = "FAIL"
SKIP = "SKIP"


class Finding:
    """One check, on one row, with the sentence a reader needs."""

    __slots__ = ("check", "status", "source_path", "detail")

    def __init__(self, check: str, status: str, source_path: str, detail: str = ""):
        self.check = check
        self.status = status
        self.source_path = source_path
        self.detail = detail

    def as_dict(self) -> dict:
        return {
            "check": self.check,
            "status": self.status,
            "source_path": self.source_path,
            "detail": self.detail,
        }

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return f"<Finding {self.check} {self.status} {self.source_path}>"


CHECK_DECLARES_ENVELOPE = "1-declares-envelope"
CHECK_STORED_IS_CIPHERTEXT = "2-stored-is-ciphertext"
CHECK_NO_PLAINTEXT_UNDER_HIGH = "3-no-plaintext-under-high"
CHECK_CONTENT_ADDRESS = "3b-content-address"
CHECK_KEK_VERSION_AGREES = "4-kek-version-agrees"
CHECK_UNWRAPS_UNDER_CUSTODY = "5-unwraps-under-custody"


def verify(rows, fetch_object, unwrap=None):
    """Run every check over `rows`, returning a list of Findings.

    `rows` are asset_inventory dicts; `fetch_object(object_key) -> bytes` reads
    the object **as stored**; `unwrap(wrapped_bytes) -> dek` is the custody seam
    and is None when no KEK is available.

    Pure apart from the two callables, which is what lets the self-test plant
    failures without a lake.
    """
    findings: list[Finding] = []

    def record(check, status, row, detail=""):
        findings.append(Finding(check, status, row.get("source_path", "?"), detail))

    for row in rows:
        path = row.get("source_path", "?")
        wrapped_b64 = row.get("wrapped_dek")
        is_high = row.get("sensitivity") == catalog.SENSITIVITY_HIGH

        # --- check 1: the row declares what it claims --------------------
        if is_high:
            if not wrapped_b64:
                record(CHECK_DECLARES_ENVELOPE, FAIL, row,
                       "sensitivity=high with no wrapped_dek: the row claims encryption "
                       "the object does not have")
            elif row.get("kek_version") is None:
                record(CHECK_DECLARES_ENVELOPE, FAIL, row,
                       "sensitivity=high with no kek_version: the wrapping key cannot be "
                       "identified, so the row is not recoverable")
            else:
                record(CHECK_DECLARES_ENVELOPE, PASS, row)
        elif wrapped_b64:
            record(CHECK_DECLARES_ENVELOPE, FAIL, row,
                   f"sensitivity={row.get('sensitivity')!r} carries a wrapped DEK; a "
                   "non-high blob is stored as-is and has no DEK")
        else:
            record(CHECK_DECLARES_ENVELOPE, PASS, row)

        # --- fetch the bytes AS STORED -----------------------------------
        try:
            body = fetch_object(row["object_key"])
        except Exception as exc:
            record(CHECK_STORED_IS_CIPHERTEXT, FAIL, row,
                   f"could not read the stored object: {type(exc).__name__}: {exc}")
            continue

        looks_encrypted = body[:4] == AOBJ_MAGIC

        # --- check 2 -----------------------------------------------------
        if is_high:
            if looks_encrypted:
                record(CHECK_STORED_IS_CIPHERTEXT, PASS, row)
            else:
                record(CHECK_STORED_IS_CIPHERTEXT, FAIL, row,
                       f"stored object does not start with {AOBJ_MAGIC!r} — it starts "
                       f"{body[:8]!r}")
        elif looks_encrypted:
            record(CHECK_STORED_IS_CIPHERTEXT, FAIL, row,
                   f"sensitivity={row.get('sensitivity')!r} but the stored object is "
                   "AOBJ ciphertext; nothing on the read path will open it")
        else:
            record(CHECK_STORED_IS_CIPHERTEXT, PASS, row)

        # --- check 3: name what is readable ------------------------------
        readable = describe_plaintext(body)
        if is_high and readable:
            record(CHECK_NO_PLAINTEXT_UNDER_HIGH, FAIL, row,
                   f"the object under this sensitivity=high row is {readable}, in the clear")
        elif is_high:
            record(CHECK_NO_PLAINTEXT_UNDER_HIGH, PASS, row)
        else:
            record(CHECK_NO_PLAINTEXT_UNDER_HIGH, PASS, row,
                   "not a high row; plaintext here is expected")

        # --- check 3b: the content address is of the PLAINTEXT ------------
        stored_digest = hashlib.sha256(body).hexdigest()
        plaintext_digest = row.get("sha256")
        if plaintext_digest is None:
            record(CHECK_CONTENT_ADDRESS, SKIP, row, "row carries no sha256 to compare")
        elif is_high:
            if stored_digest == plaintext_digest:
                record(CHECK_CONTENT_ADDRESS, FAIL, row,
                       "the stored bytes hash to the row's plaintext content address, so "
                       "what is on disk IS the plaintext — whatever its first four bytes say")
            elif hashlib.sha256(body[_AOBJ_HEADER_LEN:]).hexdigest() == plaintext_digest:
                # The same forgery with the header put back on. Prefixing five
                # bytes changes the whole-object digest, so the comparison above
                # would pass it; comparing past the header does not.
                record(CHECK_CONTENT_ADDRESS, FAIL, row,
                       f"the bytes after the {_AOBJ_HEADER_LEN}-byte envelope header hash to "
                       "this row's plaintext content address — the object is plaintext wearing "
                       "an AOBJ header, not ciphertext")
            else:
                record(CHECK_CONTENT_ADDRESS, PASS, row)
        else:
            if stored_digest == plaintext_digest:
                record(CHECK_CONTENT_ADDRESS, PASS, row)
            else:
                record(CHECK_CONTENT_ADDRESS, FAIL, row,
                       "a non-high object must be stored as-is, but the stored bytes do not "
                       "hash to its content address")

        # --- checks 4 and 5 need a wrapped DEK ---------------------------
        if not wrapped_b64:
            continue

        try:
            wrapped = base64.b64decode(wrapped_b64, validate=True)
        except Exception as exc:
            record(CHECK_KEK_VERSION_AGREES, FAIL, row,
                   f"wrapped_dek is not valid base64: {exc}")
            continue

        try:
            header_version = wdek_header_kek_version(wrapped)
        except HeaderError as exc:
            record(CHECK_KEK_VERSION_AGREES, FAIL, row, str(exc))
            continue

        if row.get("kek_version") is None:
            record(CHECK_KEK_VERSION_AGREES, FAIL, row,
                   f"the envelope header says kek_version={header_version} but the catalog "
                   "row records none")
        elif int(row["kek_version"]) != header_version:
            record(CHECK_KEK_VERSION_AGREES, FAIL, row,
                   f"catalog says kek_version={row['kek_version']}, envelope header says "
                   f"{header_version} — the duplicate has drifted")
        else:
            record(CHECK_KEK_VERSION_AGREES, PASS, row)

        # --- check 5: custody --------------------------------------------
        if unwrap is None:
            record(CHECK_UNWRAPS_UNDER_CUSTODY, SKIP, row,
                   "no KEK available to this run — NOT a pass: whether this row can still "
                   "be opened is unknown")
            continue
        try:
            dek = unwrap(wrapped)
        except Exception as exc:
            record(CHECK_UNWRAPS_UNDER_CUSTODY, FAIL, row,
                   f"the wrapped DEK does not unwrap under the KEK in custody "
                   f"({type(exc).__name__}) — this row is sealed under a key nobody holds, "
                   "which is data loss rather than security")
            continue
        if not isinstance(dek, (bytes, bytearray)) or len(dek) != 32:
            record(CHECK_UNWRAPS_UNDER_CUSTODY, FAIL, row,
                   f"unwrapped to {len(dek) if hasattr(dek, '__len__') else '?'} bytes, "
                   "not a 32-byte AES-256 DEK")
        else:
            record(CHECK_UNWRAPS_UNDER_CUSTODY, PASS, row)

    return findings


def verdict(findings) -> tuple[bool, dict]:
    """(green, counts). A SKIP is never green — see #4273."""
    counts = {PASS: 0, FAIL: 0, SKIP: 0}
    for finding in findings:
        counts[finding.status] += 1
    return counts[FAIL] == 0 and counts[SKIP] == 0, counts


# --------------------------------------------------------------------------
# Reporting.
# --------------------------------------------------------------------------

def render(findings, stream=sys.stdout) -> None:
    """Group by check, failures first within each group.

    Grouped by check rather than by row because the two questions an operator
    actually asks are "is anything unencrypted?" and "is anything unopenable?",
    and both are answered by one group. A per-row listing buries a single FAIL
    among hundreds of PASS lines.
    """
    by_check: dict[str, list[Finding]] = {}
    for finding in findings:
        by_check.setdefault(finding.check, []).append(finding)

    for check in sorted(by_check):
        group = by_check[check]
        failed = [f for f in group if f.status == FAIL]
        skipped = [f for f in group if f.status == SKIP]
        passed = len(group) - len(failed) - len(skipped)
        headline = FAIL if failed else (SKIP if skipped else PASS)
        print(f"[{headline}] {check} — {passed} pass, {len(failed)} fail, "
              f"{len(skipped)} skip", file=stream)
        for finding in failed + skipped:
            print(f"    [{finding.status}] {finding.source_path}: {finding.detail}",
                  file=stream)


# --------------------------------------------------------------------------
# Live adapters.
# --------------------------------------------------------------------------

ASSET_QUERY = """
    SELECT sha256, object_key, source_path, sensitivity, wrapped_dek, kek_version
    FROM lake.main.asset_inventory
    ORDER BY source_path
"""


def _connect_lake(bucket, endpoint, region, dsn):
    """Attach the DuckLake catalog READ-ONLY.

    Read-only is not decoration: a verification harness that could write is a
    harness that could repair what it is meant to report, and the first time
    that matters is the run where somebody is deciding whether real data is
    safe. Mirrors `lake_ingest.py::_connect_lake` otherwise.
    """
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
        f"(DATA_PATH 's3://{bucket}/bronze/', READ_ONLY)"
    )
    return con


def _s3_client(endpoint, region):
    import boto3

    return boto3.client(
        "s3",
        endpoint_url=f"http://{endpoint}",
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=region,
    )


def _custody_unwrap():
    """An `unwrap(wrapped) -> dek` bound to the KEK in custody, or None.

    None means "this run holds no key", which surfaces as SKIP on check 5 and
    keeps the verdict off green. It never means "assume fine".
    """
    if not CRYPTO_AVAILABLE:
        return None
    if not os.environ.get("LAKE_KEK_HEX"):
        return None
    from kek_loader import load_kek_from_env

    kek = load_kek_from_env()
    return lambda wrapped: dek_envelope.unwrap_dek(wrapped, kek)


def run_live(argv_json=False) -> int:
    bucket = os.environ["LAKE_S3_BUCKET"]
    endpoint = os.environ["LAKE_S3_ENDPOINT"]
    region = os.environ.get("LAKE_S3_REGION", "garage")
    dsn = os.environ["LAKE_CATALOG_DSN"]

    con = _connect_lake(bucket, endpoint, region, dsn)
    cursor = con.execute(ASSET_QUERY)
    columns = [d[0] for d in cursor.description]
    rows = [dict(zip(columns, r)) for r in cursor.fetchall()]

    s3 = _s3_client(endpoint, region)

    def fetch_object(key):
        return s3.get_object(Bucket=bucket, Key=key)["Body"].read()

    unwrap = _custody_unwrap()
    findings = verify(rows, fetch_object, unwrap)
    green, counts = verdict(findings)

    if argv_json:
        print(json.dumps({
            "green": green,
            "counts": counts,
            "crypto_available": CRYPTO_AVAILABLE,
            "kek_in_custody": unwrap is not None,
            "rows": len(rows),
            "findings": [f.as_dict() for f in findings],
        }, indent=2))
        return 0 if green else 1

    print(f"lake at-rest verification — {len(rows)} catalog row(s) in {bucket}")
    print(f"envelope format read from: "
          f"{'dek_envelope (canonical)' if CRYPTO_AVAILABLE else 'the mirrored header constants'}")
    if unwrap is None:
        print("KEK in custody: NO — check 5 cannot run and the verdict cannot be green")
    else:
        print("KEK in custody: yes")
    print()
    render(findings)
    print()
    print(f"{counts[PASS]} pass, {counts[FAIL]} fail, {counts[SKIP]} skip — "
          f"{'GREEN' if green else 'NOT GREEN'}")
    return 0 if green else 1


# --------------------------------------------------------------------------
# Self-test — the harness proved by making it fail. No lake, no docker.
# --------------------------------------------------------------------------

def _self_test() -> bool:
    """Plant every failure this harness exists to catch and require it to catch it.

    The point is not that the green case is green. It is that a harness nobody
    has watched go red is not evidence of anything, and #4273 asks for the
    harness to be *proven* on synthetic data before real data is loaded.
    """
    checks = []

    def check(label, ok, detail=""):
        checks.append(ok)
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + (f" — {detail}" if detail else ""))

    def statuses(findings, check_name):
        return [f.status for f in findings if f.check == check_name]

    def sealed(plaintext, kek_version=1):
        """An AOBJ-shaped object and its WDEK-shaped wrapped DEK, without crypto.

        Structurally faithful to dek_envelope's layout — which is all the checks
        under test parse — and deliberately not real encryption: this self-test
        must run on a host with no `cryptography`, which is the environment the
        pinned client image actually is.
        """
        body = _MIRROR_AOBJ_HEADER.pack(_MIRROR_AOBJ_MAGIC, 1) + b"\x00" * 16 + plaintext[::-1]
        wrapped = _MIRROR_WDEK_HEADER.pack(_MIRROR_WDEK_MAGIC, 1, kek_version) + b"\x11" * 60
        return body, base64.b64encode(wrapped).decode("ascii")

    plaintext = b"%PDF-1.4 SYNTHETIC FAKE-MEDICAL-NOTE do not treat as real"
    digest = hashlib.sha256(plaintext).hexdigest()
    body, wrapped_b64 = sealed(plaintext)

    def row(**overrides):
        base = {
            "sha256": digest,
            "object_key": "bronze/blobs/sha256/aa/bb/" + digest,
            "source_path": "/synthetic/documents/fake.pdf",
            "sensitivity": catalog.SENSITIVITY_HIGH,
            "wrapped_dek": wrapped_b64,
            "kek_version": 1,
        }
        base.update(overrides)
        return base

    store = {}

    def fetch(key):
        return store[key]

    def good_unwrap(_wrapped):
        return b"\x00" * 32

    # --- the happy path, so the plants below are not trivially red --------
    healthy = row()
    store[healthy["object_key"]] = body
    findings = verify([healthy], fetch, good_unwrap)
    green, counts = verdict(findings)
    check("a correctly encrypted high row is green", green, str(counts))

    # --- plant 1: plaintext sitting under a high row ----------------------
    store[healthy["object_key"]] = plaintext
    findings = verify([healthy], fetch, good_unwrap)
    check("plaintext under a high row is caught",
          FAIL in statuses(findings, CHECK_STORED_IS_CIPHERTEXT))
    check("and the report names what it found",
          any("a PDF" in f.detail for f in findings if f.check == CHECK_NO_PLAINTEXT_UNDER_HIGH))

    # --- plant 2: a FORGED AOBJ header over otherwise-plaintext bytes -----
    # Passes the magic-byte check by construction. Only the content-address
    # cross-check catches it, which is why that check exists.
    forged = _MIRROR_AOBJ_HEADER.pack(_MIRROR_AOBJ_MAGIC, 1) + plaintext
    store[healthy["object_key"]] = forged
    findings = verify([healthy], fetch, good_unwrap)
    check("a forged AOBJ header does fool the magic-byte check",
          FAIL not in statuses(findings, CHECK_STORED_IS_CIPHERTEXT))
    check("but the content-address cross-check sees past the header",
          FAIL in statuses(findings, CHECK_CONTENT_ADDRESS))
    check("and the plaintext sniff independently names it",
          FAIL in statuses(findings, CHECK_NO_PLAINTEXT_UNDER_HIGH))

    # And the sharper form: bytes that hash to the plaintext address.
    store[healthy["object_key"]] = plaintext
    findings = verify([healthy], fetch, good_unwrap)
    check("stored bytes hashing to the plaintext address are caught",
          FAIL in statuses(findings, CHECK_CONTENT_ADDRESS))

    # --- plant 3: a high row that declares no envelope --------------------
    store[healthy["object_key"]] = body
    findings = verify([row(wrapped_dek=None)], fetch, good_unwrap)
    check("a high row with no wrapped DEK is caught",
          FAIL in statuses(findings, CHECK_DECLARES_ENVELOPE))
    findings = verify([row(kek_version=None)], fetch, good_unwrap)
    check("a high row with no kek_version is caught",
          FAIL in statuses(findings, CHECK_DECLARES_ENVELOPE))

    # --- plant 4: a normal row carrying a wrapped DEK ---------------------
    normal_plain = b"SYNTHETIC fake invoice, stored in the clear on purpose"
    normal = row(sensitivity=catalog.SENSITIVITY_NORMAL,
                 sha256=hashlib.sha256(normal_plain).hexdigest(),
                 object_key="bronze/blobs/sha256/cc/dd/normal",
                 kek_version=None)
    store[normal["object_key"]] = normal_plain
    findings = verify([normal], fetch, good_unwrap)
    check("a normal row carrying a wrapped DEK is caught",
          FAIL in statuses(findings, CHECK_DECLARES_ENVELOPE))

    clean_normal = dict(normal, wrapped_dek=None)
    findings = verify([clean_normal], fetch, good_unwrap)
    green, _ = verdict(findings)
    check("a clean normal row is green", green)

    # --- plant 5: the kek_version duplicate has drifted -------------------
    store[healthy["object_key"]] = body
    findings = verify([row(kek_version=7)], fetch, good_unwrap)
    check("a kek_version that disagrees with the envelope header is caught",
          FAIL in statuses(findings, CHECK_KEK_VERSION_AGREES))

    # --- plant 6: sealed under a key nobody holds -------------------------
    def failing_unwrap(_wrapped):
        raise ValueError("GCM tag mismatch")

    findings = verify([healthy], fetch, failing_unwrap)
    check("a DEK that will not unwrap under the KEK in custody is caught",
          FAIL in statuses(findings, CHECK_UNWRAPS_UNDER_CUSTODY))
    check("and it is described as data loss rather than as a security finding",
          any("data loss" in f.detail for f in findings
              if f.check == CHECK_UNWRAPS_UNDER_CUSTODY))

    # --- the rule that makes the whole thing worth anything ---------------
    findings = verify([healthy], fetch, None)
    green, counts = verdict(findings)
    check("with no KEK, check 5 is SKIP and not PASS",
          statuses(findings, CHECK_UNWRAPS_UNDER_CUSTODY) == [SKIP])
    check("and a skipped check keeps the verdict off green", not green, str(counts))

    # --- an unreadable object is a failure, not an absence ----------------
    findings = verify([row(object_key="bronze/blobs/sha256/no/such/key")], fetch, good_unwrap)
    check("an object that cannot be read is a failure",
          FAIL in statuses(findings, CHECK_STORED_IS_CIPHERTEXT))

    print(f"\nlake_verify_at_rest: {sum(checks)}/{len(checks)} checks passed")
    return all(checks)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify that lake data is envelope-encrypted at rest (#4273).",
    )
    parser.add_argument("--self-test", action="store_true",
                        help="prove the harness against planted failures; needs no lake")
    parser.add_argument("--json", action="store_true",
                        help="emit machine-readable findings (for #4238-D1's gate)")
    args = parser.parse_args(argv)

    if args.self_test:
        return 0 if _self_test() else 1
    return run_live(argv_json=args.json)


if __name__ == "__main__":
    raise SystemExit(main())
