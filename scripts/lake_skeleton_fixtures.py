"""Seed the phase-0 lake skeleton with obviously-synthetic fixtures.

DATA_LAKE_DESIGN.md §2 (medallion mapping) and §11.0 (guardrail).

The fixtures exist to make the explorer walkable before any real data exists,
so they have two jobs and the second one is the safety-critical one:

  1. exercise every shape the explorer must render — tabular silver tables,
     content-addressed bronze blobs, PDFs and images with extracted text and
     thumbnails, an asset inventory carrying a `sensitivity=high` row, and gold
     marts;
  2. be impossible to mistake for the operator's data. Absurd names, dates in
     2999, amounts in a reserved range, and every free-text field prefixed
     `SYNTHETIC — ` or `FAKE-`. A screenshot of this data must never raise the
     question "wait, is that real?".

§2's layer contracts are followed rather than approximated: binary blobs live
once in bronze, content-addressed at `bronze/blobs/sha256/ab/cd/<hash>`, and
only their *derived artifacts* (extracted text, thumbnails, metadata rows)
appear in silver. Copying a PDF three times to "promote" it would be cargo cult.

Idempotent: content-addressed blobs land at the same key on every run, and the
silver/gold tables are replaced rather than appended to.

Run it with `scripts/lake-skeleton.sh seed`.
"""

import hashlib
import os
import struct
import sys
import zlib

import boto3
import duckdb

# Layer-2 envelope encryption (DATA_LAKE_DESIGN.md §9, task #4134 / #4120-D). The
# format + object crypto (dek_envelope), the storage gate (envelope_store), and
# the fail-closed KEK loader (kek_loader) live in scripts/kek/ — mounted at
# ./kek beside this script both on disk and in the client container (/work/kek).
_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(_HERE, "kek"))
from envelope_store import storage_body_and_wrapped_dek  # noqa: E402
from kek_loader import ENV_KEK_FINGERPRINT, ENV_KEK_HEX, load_kek_from_env  # noqa: E402

# The catalog schema + sensitivity-intake contract (#4270 / #4238-A2), shared
# with the real ingest runner (#4271) so the synthetic seed and the real load
# write the same columns under the same rules. Mounted at /work/lake in the
# client container beside /work/kek.
sys.path.insert(0, os.path.join(_HERE, "lake"))
import catalog  # noqa: E402

BUCKET = os.environ["LAKE_S3_BUCKET"]
ENDPOINT = os.environ["LAKE_S3_ENDPOINT"]
REGION = os.environ["LAKE_S3_REGION"]
DSN = os.environ["LAKE_CATALOG_DSN"]

# Which KEK version wraps DEKs written this run (the wrapped-DEK header records
# it, so a future rotation can hold more than one). Phase 0b uses version 1.
KEK_VERSION = int(os.environ.get("LAKE_KEK_VERSION", "1"))

_kek_cache: dict[str, bytes] = {}


def _get_kek():
    """The KEK for encrypting sensitivity=high blobs — loaded once, fail-closed.

    Env-only: this loader runs non-interactively under `lake-skeleton.sh seed`,
    so there is no TTY to prompt; the launcher passes the off-cell hex through
    the one-shot LAKE_KEK_HEX env var (never on disk). If a high-sensitivity blob
    must be written and no KEK is present, refuse — writing high data unencrypted
    is exactly what §9 forbids. For the synthetic skeleton, pass a throwaway
    synthetic KEK; a real KEK is only needed once real high-sensitivity data is
    ingested (the operator ceremony, #4133).
    """
    if "kek" not in _kek_cache:
        kek = load_kek_from_env(
            expected_fingerprint=os.environ.get(ENV_KEK_FINGERPRINT) or None
        )
        if kek is None:
            raise SystemExit(
                f"refusing to ingest a sensitivity=high blob without a KEK: set "
                f"{ENV_KEK_HEX} to the off-cell grouped hex (never on disk). "
                "Fail-closed per DATA_LAKE_DESIGN.md §9 layer 2."
            )
        _kek_cache["kek"] = kek
    return _kek_cache["kek"]

# The fixture vocabulary. `verify` asserts against these, so anything added here
# must stay just as unmistakable — this list IS the guardrail's definition of
# "obviously fake".
PEOPLE = [
    "SYNTHETIC — Ada Notarealperson",
    "SYNTHETIC — Bob Doesnotexist",
    "SYNTHETIC — Carol Placeholder",
    "SYNTHETIC — Dave Fictitious",
    "SYNTHETIC — Erin Madeupname",
]
# Dates are all in 2999: no real record can plausibly carry them.
FAKE_YEAR = 2999

# The fixtures' own dataset id. Prefixed like every other fake value so a
# screenshot of the catalog never raises "wait, is that a real dataset?".
SYNTHETIC_DATASET_ID = "SYNTHETIC — FAKE-DATASET-000"


# --------------------------------------------------------------------------
# Media synthesis. Real, valid files — just tiny, and hand-built so the client
# image needs no image-processing stack for three fixture pictures.
# --------------------------------------------------------------------------


def make_png(width, height, rgb):
    """A valid single-colour PNG, built from zlib + struct."""

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def make_pdf(title, body_line):
    """A minimal single-page PDF with one line of visible text."""
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 120] "
        b"/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        None,  # content stream, filled below
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    text = (
        f"BT /F1 12 Tf 20 80 Td ({title}) Tj "
        f"0 -20 Td ({body_line}) Tj ET"
    ).encode("ascii", "replace")
    objects[3] = b"<< /Length %d >>\nstream\n%s\nendstream" % (len(text), text)

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, obj in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n%s\nendobj\n" % (i, obj)
    xref_at = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (
        len(objects) + 1,
        xref_at,
    )
    return bytes(out)


# --------------------------------------------------------------------------
# Bronze — content-addressed blobs at §2's exact layout.
# --------------------------------------------------------------------------

s3 = boto3.client(
    "s3",
    endpoint_url=f"http://{ENDPOINT}",
    aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
    aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
    region_name=REGION,
)


def put_blob(payload, stored_body=None):
    """Store a blob at bronze/blobs/sha256/ab/cd/<hash>; return (hash, key, size).

    The content address and reported size are of the *plaintext* ``payload`` — a
    blob's identity and size are stable across encryption, and keying by the
    plaintext hash keeps the silver joins (extracted_text, image_metadata) and
    lets the read path verify the decrypted bytes against the row. ``stored_body``,
    when given, is the bytes actually PUT (the envelope-encrypted object); §9 says
    the high-sensitivity marker is an inventory *column*, not a folder convention,
    so an encrypted blob sits at the same key layout and differs only in its row.

    The two-level prefix is not decoration: it keeps any single listing prefix
    small once the real lake holds hundreds of thousands of blobs.
    """
    digest = hashlib.sha256(payload).hexdigest()
    key = f"bronze/blobs/sha256/{digest[:2]}/{digest[2:4]}/{digest}"
    s3.put_object(Bucket=BUCKET, Key=key, Body=payload if stored_body is None else stored_body)
    return digest, key, len(payload)


BLOBS = []


def blob(kind, source_path, mime, payload, sensitivity=None):
    # The declared sensitivity goes through the intake contract rather than
    # straight into the row (#4270): the fixtures are the contract's first
    # caller, so the synthetic seed proves the fail-closed rule on every run
    # instead of leaving it exercised only by unit tests. Note the default is
    # now None, not "normal" — under the contract an undeclared blob resolves
    # to high and gets encrypted, so the fixtures below declare "normal"
    # explicitly wherever they mean it.
    sensitivity, sensitivity_source = catalog.resolve_sensitivity(sensitivity)

    # §9 layer 2: a sensitivity=high blob is envelope-encrypted before it reaches
    # Garage; its wrapped DEK rides in the inventory row (base64). Normal blobs
    # store as-is with no wrapped DEK.
    is_high = sensitivity == catalog.SENSITIVITY_HIGH
    stored_body, wrapped_dek = storage_body_and_wrapped_dek(
        payload, sensitivity, _get_kek() if is_high else b"", KEK_VERSION
    )
    digest, key, size = put_blob(payload, stored_body=stored_body if is_high else None)
    BLOBS.append(
        {
            "kind": kind,
            "sha256": digest,
            "object_key": key,
            "source_path": source_path,
            "mime": mime,
            "size_bytes": size,
            "sensitivity": sensitivity,
            "sensitivity_source": sensitivity_source,
            "wrapped_dek": wrapped_dek,
            # Only a high blob has a DEK to wrap, so only a high row names the
            # key that wraps it.
            "kek_version": KEK_VERSION if is_high else None,
        }
    )
    return digest


# Documents. One is sensitivity=high — §2 is explicit that the high-sensitivity
# marker is a *column*, not a folder convention, so it lives at the same path
# layout as everything else and differs only in the inventory row.
pdf_invoice = blob(
    "document",
    "/synthetic/documents/fake-invoice-2999.pdf",
    "application/pdf",
    make_pdf("SYNTHETIC INVOICE - NOT REAL", "Billed to: SYNTHETIC - Ada Notarealperson"),
    sensitivity="normal",
)
pdf_medical = blob(
    "document",
    "/synthetic/documents/fake-medical-note-2999.pdf",
    "application/pdf",
    make_pdf("SYNTHETIC MEDICAL NOTE - NOT REAL", "Patient: SYNTHETIC - Bob Doesnotexist"),
    sensitivity="high",
)

# Images plus their thumbnails. The thumbnail is its own blob: §2 puts derived
# artifacts in silver, and the inventory row points at both.
img_full = blob(
    "image", "/synthetic/photos/fake-photo-teal.png", "image/png", make_png(64, 48, (0, 128, 128)),
    sensitivity="normal",
)
img_thumb = blob(
    "image",
    "/synthetic/photos/.thumbs/fake-photo-teal.png",
    "image/png",
    make_png(16, 12, (0, 128, 128)),
    sensitivity="normal",
)
img2_full = blob(
    "image", "/synthetic/photos/fake-photo-amber.png", "image/png", make_png(64, 48, (200, 140, 0)),
    sensitivity="normal",
)
img2_thumb = blob(
    "image",
    "/synthetic/photos/.thumbs/fake-photo-amber.png",
    "image/png",
    make_png(16, 12, (200, 140, 0)),
    sensitivity="normal",
)

# Audio: a valid-enough WAV header plus silence — the explorer needs a row and a
# transcript, not audible content.
wav = b"RIFF" + struct.pack("<I", 36 + 800) + b"WAVEfmt " + struct.pack(
    "<IHHIIHH", 16, 1, 1, 8000, 8000, 1, 8
) + b"data" + struct.pack("<I", 800) + b"\x80" * 800
audio_blob = blob(
    "audio", "/synthetic/audio/fake-voice-memo.wav", "audio/wav", wav, sensitivity="normal"
)

# A raw message export, standing in for the mbox/JSON/XML exports of §2.
messages_export = blob(
    "message_export",
    "/synthetic/messages/fake-telegram-export.json",
    "application/json",
    b'[{"from":"SYNTHETIC - Carol Placeholder","text":"FAKE-MESSAGE-001"}]',
    sensitivity="normal",
)

print(f"bronze: {len(BLOBS)} content-addressed blobs")

# --------------------------------------------------------------------------
# Silver + gold — DuckLake-managed tables.
# --------------------------------------------------------------------------

con = duckdb.connect()
for ext in ("httpfs", "postgres", "ducklake"):
    con.execute(f"LOAD {ext}")

con.execute(
    f"""
    CREATE OR REPLACE SECRET garage (
        TYPE s3, KEY_ID '{os.environ["AWS_ACCESS_KEY_ID"]}',
        SECRET '{os.environ["AWS_SECRET_ACCESS_KEY"]}',
        ENDPOINT '{ENDPOINT}', REGION '{REGION}', URL_STYLE 'path', USE_SSL false
    )
    """
)
# DATA_INLINING_ROW_LIMIT 0: without it DuckLake keeps small writes as rows in
# the catalog database instead of parquet in the object store. See
# docs/LAKE_SKELETON.md — it would route real data around §9's encryption.
con.execute(
    f"ATTACH 'ducklake:postgres:{DSN}' AS lake "
    f"(DATA_PATH 's3://{BUCKET}/bronze/', DATA_INLINING_ROW_LIMIT 0)"
)
con.execute("USE lake")


def replace(table, columns, rows):
    con.execute(f"DROP TABLE IF EXISTS {table}")
    con.execute(f"CREATE TABLE {table} ({columns})")
    placeholders = ", ".join("?" for _ in rows[0])
    con.executemany(f"INSERT INTO {table} VALUES ({placeholders})", rows)
    print(f"silver/gold: {table} — {len(rows)} row(s)")


# --- silver: asset inventory (one row per blob, §2's blob catalog) ---------
# Schema and row order come from scripts/lake/catalog.py (#4270), shared with the
# real ingest runner. catalog.asset_row() refuses an incoherent row — a high row
# with no wrapped DEK, a normal row carrying one — so the seed cannot write the
# very mismatch #4273's verification harness exists to detect.
replace(
    "asset_inventory",
    catalog.ASSET_INVENTORY_COLUMNS,
    [
        catalog.asset_row(
            sha256=b["sha256"], object_key=b["object_key"], source_path=b["source_path"],
            mime=b["mime"], size_bytes=b["size_bytes"], kind=b["kind"],
            sensitivity=b["sensitivity"], sensitivity_source=b["sensitivity_source"],
            # base64 wrapped DEK for a sensitivity=high blob; NULL otherwise. The
            # read path (explorer, #4199) keys "is this encrypted?" on this column.
            wrapped_dek=b["wrapped_dek"], kek_version=b["kek_version"],
            ingested_at=f"{FAKE_YEAR}-01-0{(i % 9) + 1} 0{(i % 9) + 1}:11:11",
            ingest_run_id=f"FAKE-RUN-{(i % 3) + 1:03d}",
            # The fixtures are their own dataset, and an obviously fake one — a
            # real dataset_id points at an operator intake record (#4269).
            dataset_id=SYNTHETIC_DATASET_ID,
            retention_class="SYNTHETIC — fake-retention",
            jurisdiction="SYNTHETIC — fake-jurisdiction",
        )
        for i, b in enumerate(BLOBS)
    ],
)

# --- silver: extracted text (derived from the PDF blobs) ------------------
replace(
    "extracted_text",
    "sha256 VARCHAR, page INTEGER, content VARCHAR, extractor VARCHAR",
    [
        (pdf_invoice, 1, "SYNTHETIC INVOICE - NOT REAL. Billed to: SYNTHETIC — Ada Notarealperson. Total FAKE-AMOUNT 11.11", "FAKE-pdftotext-0.0.0"),
        (pdf_medical, 1, "SYNTHETIC MEDICAL NOTE - NOT REAL. Patient: SYNTHETIC — Bob Doesnotexist. Diagnosis: FAKE-CONDITION-001", "FAKE-pdftotext-0.0.0"),
    ],
)

# --- silver: image metadata + thumbnail refs ------------------------------
replace(
    "image_metadata",
    """
    sha256 VARCHAR, thumbnail_sha256 VARCHAR, width INTEGER, height INTEGER,
    camera VARCHAR, taken_on DATE
    """,
    [
        (img_full, img_thumb, 64, 48, "SYNTHETIC — Nonexistent Cam 9000", f"{FAKE_YEAR}-03-03"),
        (img2_full, img2_thumb, 64, 48, "SYNTHETIC — Nonexistent Cam 9000", f"{FAKE_YEAR}-04-04"),
    ],
)

# --- silver: audio transcripts -------------------------------------------
replace(
    "audio_transcripts",
    "sha256 VARCHAR, duration_seconds DOUBLE, transcript VARCHAR, model VARCHAR",
    [(audio_blob, 0.1, "SYNTHETIC — this transcript is fake. FAKE-UTTERANCE-001", "FAKE-whisper-0.0.0")],
)

# --- silver: unified messages (§2 folds all channels into one table) ------
replace(
    "messages",
    """
    message_id VARCHAR, channel VARCHAR, sender VARCHAR, recipients VARCHAR,
    sent_at DATE, body VARCHAR, attachment_sha256 VARCHAR
    """,
    [
        (f"FAKE-MESSAGE-{i:03d}", ch, PEOPLE[i % len(PEOPLE)], PEOPLE[(i + 1) % len(PEOPLE)],
         f"{FAKE_YEAR}-0{(i % 9) + 1}-1{i % 9}", f"SYNTHETIC — placeholder message body {i}",
         messages_export if i == 0 else None)
        for i, ch in enumerate(["telegram", "sms", "email", "telegram", "sms", "email"])
    ],
)

# --- silver: a typed table export, standing in for a Postgres source ------
replace(
    "finance_transactions",
    "txn_id VARCHAR, booked_on DATE, counterparty VARCHAR, amount_eur DOUBLE, category VARCHAR",
    [
        (f"FAKE-TXN-{i:03d}", f"{FAKE_YEAR}-{(i % 12) + 1:02d}-15", PEOPLE[i % len(PEOPLE)],
         round(11.11 * (i + 1), 2), "SYNTHETIC — placeholder category")
        for i in range(12)
    ],
)

# --- gold: curated marts the Overview page reads --------------------------
replace(
    "gold_finance_monthly",
    "month VARCHAR, txn_count BIGINT, total_eur DOUBLE",
    [(f"{FAKE_YEAR}-{m:02d}", 1, round(11.11 * m, 2)) for m in range(1, 13)],
)

replace(
    "gold_timeline",
    "happened_on DATE, source VARCHAR, entity VARCHAR, summary VARCHAR",
    [
        (f"{FAKE_YEAR}-01-01", "SYNTHETIC — fake-source-a", PEOPLE[0], "SYNTHETIC — placeholder timeline event 1"),
        (f"{FAKE_YEAR}-02-02", "SYNTHETIC — fake-source-b", PEOPLE[1], "SYNTHETIC — placeholder timeline event 2"),
        (f"{FAKE_YEAR}-03-03", "SYNTHETIC — fake-source-c", PEOPLE[2], "SYNTHETIC — placeholder timeline event 3"),
    ],
)

replace(
    "gold_source_freshness",
    """
    source VARCHAR, last_run_id VARCHAR, last_success_on DATE,
    sla_hours INTEGER, status VARCHAR
    """,
    [
        ("SYNTHETIC — fake-source-a", "FAKE-RUN-001", f"{FAKE_YEAR}-01-01", 24, "green"),
        ("SYNTHETIC — fake-source-b", "FAKE-RUN-002", f"{FAKE_YEAR}-01-01", 24, "amber"),
        ("SYNTHETIC — fake-source-c", "FAKE-RUN-003", f"{FAKE_YEAR}-01-01", 24, "red"),
    ],
)

# --- silver: the connector run ledger (§8's Runs & health page) -----------
# Schema and row order from scripts/lake/catalog.py (#4270). The ledger gained
# the audit columns a real load has to answer for — which dataset, which runner,
# which KEK, and how the objects split by sensitivity.
replace(
    "ingest_runs",
    catalog.INGEST_RUNS_COLUMNS,
    [
        catalog.run_row(
            run_id=f"FAKE-RUN-{n:03d}", source=f"SYNTHETIC — fake-source-{suffix}",
            started_on=f"{FAKE_YEAR}-01-01 0{n}:11:11", duration_seconds=duration,
            files_seen=files, bytes_ingested=written, status=status,
            dataset_id=SYNTHETIC_DATASET_ID, runner_version="FAKE-skeleton-0.0.0",
            # Only the run that wrote the one high blob names a KEK; a run with
            # nothing high to wrap has no key to record.
            kek_version=KEK_VERSION if high else None,
            objects_high=high, objects_normal=files - high,
        )
        for n, suffix, duration, files, written, status, high in (
            (1, "a", 11.11, 3, 1111, "success", 1),
            (2, "b", 22.22, 2, 2222, "success", 0),
            (3, "c", 33.33, 1, 3333, "failed", 0),
        )
    ],
)

print("\nseeded: bronze blobs + 8 silver/gold tables")
sys.exit(0)
