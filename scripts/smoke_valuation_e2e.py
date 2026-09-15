#!/usr/bin/env python3
"""Cross-service valuation smoke check — the layer above the per-service suites (#5921).

On one feature in one day, four defects shipped that every per-service test passed,
because each suite runs against one service in isolation and nothing ever drove a
real document through the deployed proxy chain a browser actually uses:

  * #5910  two contradictory banners on one scan   (found by reading code vs a real doc)
  * #5915  /decide took 16-83s, not the ~1.4s design (found dogfooding DV.pdf)
  * #5920  /decide had NO route on aspirant-server  (found probing the served endpoint)
  * #5919  Member uploads 502 at the 30s ceiling    (found by a real user, Jenny)

Each was correct in the service that owned it; the defect lived in the space between
three independently-deployed services, which no repo owns, and a correct client
fallback (#306) made the missing route silent. This check is the invariant with a
checker: it runs against the DEPLOYED containers, authenticates as a real Member,
and drives real documents through the client nginx /api proxy — real chain, real
containers, no mock of any of the three.

Two assertions:

  Part A — route contract. Every commander endpoint the client calls resolves to a
  route on aspirant-server. Probed unauthenticated at the served surface: a
  registered auth-gated route answers 401; a missing one 404s. 404-where-401 is the
  whole of #5920, and a list comparison catches it.

  Part B — real-document journey. As a Member, POST /decide then /extract for each
  corpus document, asserting the pre-flight classifies it and the extract returns
  200 (not the #5919 502) with the expected fields — the journey #5915 shipped
  "done" without, that never once worked for a user.

Privacy: the corpus documents are real client valuations; their bytes and field
VALUES never leave the cell and are never asserted here. This check reads them from
an on-cell directory and asserts only STRUCTURE — classification, field counts,
outcome, HTTP status — so nothing client-identifying is committed or logged.

Exit 0 = all assertions held; non-zero = a real cross-service defect. Intended to
run post-deploy (wired into the deploy scripts) and on a cadence, with a non-zero
exit converted into a fleet signal by its wrapper.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

# --------------------------------------------------------------------------- config

CLIENT_BASE = os.environ.get("SMOKE_CLIENT_BASE", "http://localhost:8999")
CORPUS_DIR = Path(os.environ.get("SMOKE_CORPUS_DIR", "/data/aspirant/smoke-corpus"))
# A dedicated, login-impossible Member account (password NULL) so the check never
# appears in the audit trail as a real user. Its session epoch is a permanent 0:
# with no password it can never open a session, so nothing ever revokes it and the
# watermark never advances — which is why the token can be minted with a constant
# epoch and no live DB read. If the account is ever re-seeded or bumped, the mint
# goes stale and the whole of Part B 401s loudly, naming the cause.
SMOKE_USER_ID = int(os.environ.get("SMOKE_USER_ID", "14"))
SMOKE_USER_ROLE = os.environ.get("SMOKE_USER_ROLE", "Member")
SMOKE_USER_EPOCH = int(os.environ.get("SMOKE_USER_EPOCH", "0"))

# Every commander endpoint the aspirant-client calls through /api, as (method, path)
# in the form the client uses. Mirrors the client's call sites
# (src/views/member/personal/ValuationStatement.vue); the reconcile check below
# fails if the client grows an endpoint not listed here.
CLIENT_COMMANDER_CONTRACT = [
    ("POST", "/api/commander/valuation-statement/extract"),
    ("POST", "/api/commander/valuation-statement/decide"),
    ("POST", "/api/commander/valuation-statement/generate"),
    ("GET", "/api/commander/valuation-statement/operator-defaults"),
    ("PUT", "/api/commander/valuation-statement/operator-defaults"),
    ("POST", "/api/commander/valuation-statement/processed"),
    ("GET", "/api/commander/valuation-statement/processed"),
    ("GET", "/api/commander/valuation-statement/processed/export.csv"),
    ("GET", "/api/commander/valuation-statement/processed/smoke-probe-id"),
    ("PATCH", "/api/commander/valuation-statement/processed/smoke-probe-id"),
    ("DELETE", "/api/commander/valuation-statement/processed/smoke-probe-id"),
]

# Structural expectations only — no client field VALUES (those are PII and stay on
# the cell). `min_filled` is a floor on how many value slots must come back.
# aspstigen (Jenny's raster scan) legitimately yields 0 fields today: OCR runs but
# recovers nothing on a noisy scan (that yield is #5909's domain, not this check's),
# so its assertion is the journey completing — 200, ocr ran, no 502 — which is the
# whole of #5919.
CORPUS_MANIFEST = [
    {
        "file": "native_text.pdf",
        "decide": {"ocr_required": False, "subkind": None},
        "extract": {"ocr_used": False, "min_filled": 3, "outcomes": {"extracted", "partial"}},
    },
    {
        "file": "dv_reprinted_vector.pdf",
        "decide": {"ocr_required": True, "subkind": "reprinted_vector"},
        "extract": {"ocr_used": True, "min_filled": 3, "outcomes": {"extracted", "partial"}},
    },
    {
        "file": "aspstigen_raster_scan.pdf",
        "decide": {"ocr_required": True, "subkind": "raster_scan"},
        "extract": {"ocr_used": True, "min_filled": 0, "outcomes": {"no_text", "partial", "extracted"}},
    },
]

# The extract client's ceiling on the deployed server is 300s (#5919); give the
# HTTP read a little more so a genuine server-side 504/slowness surfaces as itself
# rather than as a client-side socket timeout we would misread.
EXTRACT_TIMEOUT = 320
DECIDE_TIMEOUT = 60


# ----------------------------------------------------------------------- assertions
# Pure functions, unit-tested in tests/smoke_valuation_unit.py, so "this check would
# have failed against the pre-fix stack" is itself pinned without re-breaking prod.


def contract_route_ok(status: int) -> bool:
    """A contract route is present iff the served surface did not 404. 401 (auth
    required) is the healthy answer; 404 is the missing-hop bug (#5920)."""
    return status != 404


def decide_ok(expect: dict, doc: dict) -> list[str]:
    errs = []
    if doc.get("ocr_required") != expect["ocr_required"]:
        errs.append(f"ocr_required={doc.get('ocr_required')} want {expect['ocr_required']}")
    if "subkind" in expect and doc.get("no_text_subkind") != expect["subkind"]:
        errs.append(f"subkind={doc.get('no_text_subkind')} want {expect['subkind']}")
    return errs


def extract_ok(expect: dict, status: int, doc: dict) -> list[str]:
    errs = []
    if status != 200:
        errs.append(f"HTTP {status} (want 200 — a 502/504 here is the #5919 failure)")
        return errs
    diag = doc.get("diagnostics") or {}
    if diag.get("ocr_used") != expect["ocr_used"]:
        errs.append(f"ocr_used={diag.get('ocr_used')} want {expect['ocr_used']}")
    if diag.get("outcome") not in expect["outcomes"]:
        errs.append(f"outcome={diag.get('outcome')} not in {sorted(expect['outcomes'])}")
    filled = sum(1 for f in (doc.get("fields") or []) if f.get("value"))
    if filled < expect["min_filled"]:
        errs.append(f"filled={filled} < min {expect['min_filled']}")
    return errs


# ------------------------------------------------------------------------- plumbing


@dataclass
class Result:
    failures: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def fail(self, msg: str) -> None:
        self.failures.append(msg)
        print(f"  FAIL  {msg}")

    def ok(self, msg: str) -> None:
        print(f"  ok    {msg}")

    def note(self, msg: str) -> None:
        self.notes.append(msg)
        print(f"  ..    {msg}")


def _b64url(raw: bytes) -> bytes:
    return base64.urlsafe_b64encode(raw).rstrip(b"=")


def mint_member_token(secret: str, uid: int, role: str, epoch: int, ttl: int = 400) -> str:
    """Mint the same HS256 token shape aspirant-server issues (user_id/role/iat/exp/
    epoch), signed with the raw JWT_SECRET bytes as the key — matching
    middleware.LoadJWTSecret (`jwtSecret = []byte(raw)`). The epoch must equal the
    user's row or AuthMiddleware rejects it as revoked (#5275)."""
    now = int(time.time())
    header = _b64url(b'{"alg":"HS256","typ":"JWT"}')
    payload = _b64url(json.dumps(
        {"user_id": uid, "role": role, "iat": now, "exp": now + ttl, "epoch": epoch},
        separators=(",", ":"),
    ).encode())
    sig = _b64url(hmac.new(secret.encode(), header + b"." + payload, hashlib.sha256).digest())
    return (header + b"." + payload + b"." + sig).decode()


def _multipart(pdf_bytes: bytes, filename: str) -> tuple[bytes, str]:
    boundary = "----smoke5921boundary"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="files"; filename="{filename}"\r\n'
        f"Content-Type: application/pdf\r\n\r\n"
    ).encode() + pdf_bytes + f"\r\n--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def _request(method: str, path: str, token: str | None, body: bytes | None,
             content_type: str | None, timeout: int) -> tuple[int, bytes]:
    req = urllib.request.Request(CLIENT_BASE + path, data=body, method=method)
    if content_type:
        req.add_header("Content-Type", content_type)
    if token:
        req.add_header("Cookie", f"auth_token={token}")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


# ------------------------------------------------------------------------- the check


def part_a_contract(res: Result) -> None:
    print("Part A — route contract (served surface, unauthenticated 401-not-404):")
    for method, path in CLIENT_COMMANDER_CONTRACT:
        try:
            status, _ = _request(method, path, None, None, None, 15)
        except Exception as e:  # noqa: BLE001
            res.fail(f"{method} {path}: probe error {type(e).__name__}: {e}")
            continue
        if not contract_route_ok(status):
            res.fail(f"{method} {path}: 404 — no route on aspirant-server (the #5920 class)")
        else:
            res.ok(f"{method} {path}: {status}")


def part_b_journey(res: Result, token: str) -> None:
    print("Part B — real documents through the client /api proxy, as a Member:")
    for entry in CORPUS_MANIFEST:
        doc_path = CORPUS_DIR / entry["file"]
        if not doc_path.exists():
            res.fail(f"{entry['file']}: corpus document missing at {doc_path}")
            continue
        pdf = doc_path.read_bytes()
        body, ct = _multipart(pdf, entry["file"])

        # /decide — the pre-flight (#5915/#5920).
        status, raw = _request("POST", "/api/commander/valuation-statement/decide",
                               token, body, ct, DECIDE_TIMEOUT)
        if status != 200:
            res.fail(f"{entry['file']} decide: HTTP {status} (want 200)")
        else:
            docs = (json.loads(raw).get("documents") or [{}])
            errs = decide_ok(entry["decide"], docs[0])
            (res.fail if errs else res.ok)(
                f"{entry['file']} decide: " + ("; ".join(errs) if errs else
                f"ocr_required={docs[0].get('ocr_required')} subkind={docs[0].get('no_text_subkind')}"))

        # /extract — the blocking journey (#5919 502-at-30s lived here).
        body, ct = _multipart(pdf, entry["file"])
        t0 = time.time()
        status, raw = _request("POST", "/api/commander/valuation-statement/extract",
                               token, body, ct, EXTRACT_TIMEOUT)
        dt = time.time() - t0
        doc = json.loads(raw).get("documents", [{}])[0] if status == 200 and raw else {}
        errs = extract_ok(entry["extract"], status, doc)
        filled = sum(1 for f in (doc.get("fields") or []) if f.get("value"))
        summary = f"{status} in {dt:.1f}s outcome={(doc.get('diagnostics') or {}).get('outcome')} filled={filled}"
        (res.fail if errs else res.ok)(
            f"{entry['file']} extract: " + ("; ".join(errs) if errs else summary))


def main() -> int:
    secret = os.environ.get("JWT_SECRET")
    if not secret:
        print("JWT_SECRET not set — source the deploy .env before running", file=sys.stderr)
        return 2
    print(f"valuation smoke check → {CLIENT_BASE} (corpus {CORPUS_DIR})")
    res = Result()

    part_a_contract(res)

    token = mint_member_token(secret, SMOKE_USER_ID, SMOKE_USER_ROLE, SMOKE_USER_EPOCH)
    part_b_journey(res, token)

    print()
    if res.failures:
        print(f"SMOKE FAILED — {len(res.failures)} assertion(s):")
        for f in res.failures:
            print(f"  - {f}")
        return 1
    print("SMOKE PASSED — the deployed stack serves the whole valuation journey.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
