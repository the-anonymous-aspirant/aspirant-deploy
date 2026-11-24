"""Unit test for scripts/gmail/gmail_pull.py (system_3 #8806-B1). No network.

Runs inside the aspirant-gmail:local image (tests/gmail_pull_unit.sh), which has
googleapiclient, so the fake service below raises the library's own HttpError
and GmailApi's 404 mapping is exercised, not mocked. The mailbox is
tests/fixtures/gmail/mailbox.json: synthetic messages in Gmail API v1 response
shapes at two states, S1 and S2, plus the history between them.

The acceptance: a full pull at S1 followed by an incremental pull to S2 gives
exactly the mailbox a fresh full pull at S2 gives, message by message, compared
as canonical JSON bytes.
"""
from __future__ import annotations

import base64
import contextlib
import copy
import hashlib
import io
import json
import re
import os
import stat
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "gmail"))

import httplib2  # noqa: E402
from googleapiclient.errors import HttpError  # noqa: E402

import gmail_auth  # noqa: E402
import gmail_pull  # noqa: E402

FIXTURE = json.loads((REPO / "tests" / "fixtures" / "gmail" / "mailbox.json").read_text("utf-8"))
NOW = datetime(2026, 10, 31, 12, 0, 0, tzinfo=timezone.utc)
LATER = datetime(2026, 10, 31, 13, 0, 0, tzinfo=timezone.utc)
PAGE = 2  # small, so every list call paginates


FIXTURE_ATTACHMENT_ID = "ANGjdJ-ATTACHMENT-ID-NOT-FETCHED"
FIXTURE_ATTACHMENT_SIZE = 18342


def synthetic_bytes(size: int, head: bytes = b"") -> bytes:
    body = head + bytes(range(256)) * (size // 256 + 1)
    return body[:size]


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def http_error(status: int) -> HttpError:
    return HttpError(httplib2.Response({"status": status}), b'{"error": {"code": %d}}' % status)


class _Req:
    def __init__(self, fn, log, name):
        self.fn, self.log, self.name = fn, log, name

    def execute(self, num_retries=0):
        self.log.append(self.name)
        return self.fn()


class FakeService:
    """googleapiclient's `users()` call chain over one mailbox state."""

    def __init__(self, state: str, records: list | None = None, oldest: str | None = None):
        snap = FIXTURE[state]
        self.history_id = snap["history_id"]
        self.mail = {m["id"]: copy.deepcopy(m) for m in snap["messages"]}
        self.records = records or []
        self.oldest = int(oldest or FIXTURE["oldest_history_id"])
        self.calls: list[str] = []
        # Attachment bodies by attachment id (#11557). The fixture's one PDF
        # part gets synthetic bytes of exactly its reported size.
        self.attachment_bodies = {FIXTURE_ATTACHMENT_ID: synthetic_bytes(FIXTURE_ATTACHMENT_SIZE, b"%PDF-1.4 synthetic\n")}

    def users(self):
        return self

    def getProfile(self, userId):
        answer = {"emailAddress": FIXTURE["email"], "historyId": self.history_id, "messagesTotal": len(self.mail)}
        return _Req(lambda: answer, self.calls, "getProfile")

    def messages(self):
        return _Messages(self)

    def history(self):
        return _History(self)


def _paged(items, page_token, key, extra):
    start = int(page_token or 0)
    page = dict(extra)
    chunk = items[start:start + PAGE]
    if chunk:
        page[key] = chunk
    if start + PAGE < len(items):
        page["nextPageToken"] = str(start + PAGE)
    return page


class _Messages:
    def __init__(self, svc: FakeService):
        self.svc = svc

    def list(self, userId, maxResults, pageToken=None, includeSpamTrash=False):
        svc = self.svc
        ids = sorted(
            mid for mid, m in svc.mail.items()
            if includeSpamTrash or not gmail_pull.EXCLUDED_LABELS.intersection(m["labelIds"])
        )
        refs = [{"id": i, "threadId": svc.mail[i]["threadId"]} for i in ids]
        return _Req(lambda: _paged(refs, pageToken, "messages", {"resultSizeEstimate": len(ids)}), svc.calls, "messages.list")

    def get(self, userId, id, format):
        assert format == "full"
        svc = self.svc

        def answer():
            if id not in svc.mail:
                raise http_error(404)
            return copy.deepcopy(svc.mail[id])

        return _Req(answer, svc.calls, "messages.get")

    def attachments(self):
        return _Attachments(self.svc)


class _Attachments:
    def __init__(self, svc: FakeService):
        self.svc = svc

    def get(self, userId, messageId, id):
        svc = self.svc

        def answer():
            if messageId not in svc.mail or id not in svc.attachment_bodies:
                raise http_error(404)
            data = svc.attachment_bodies[id]
            return {"size": len(data), "data": b64url(data)}

        return _Req(answer, svc.calls, "messages.attachments.get")


class _History:
    def __init__(self, svc: FakeService):
        self.svc = svc

    def list(self, userId, startHistoryId, historyTypes, maxResults, pageToken=None):
        svc = self.svc

        def answer():
            if int(startHistoryId) < svc.oldest:
                raise http_error(404)
            records = [r for r in svc.records if int(r["id"]) > int(startHistoryId)]
            return _paged(records, pageToken, "history", {"historyId": svc.history_id})

        return _Req(answer, svc.calls, "history.list")


def api(state, history=None, oldest=None):
    svc = FakeService(state, history, oldest)
    return gmail_pull.GmailApi(svc), svc


def by_id(messages):
    return {m["id"]: m for m in messages}


def load_export(run_dir: str) -> dict:
    return json.loads((Path(run_dir) / gmail_pull.EXPORT_NAME).read_text("utf-8"))


SECRET_STRINGS = sorted(
    {
        h["value"]
        for snap in ("s1", "s2")
        for m in FIXTURE[snap]["messages"]
        for h in m["payload"].get("headers", [])
        if h["name"] in ("Subject", "From", "To", "Cc")
    }
    | {"Hej! Ses vi", "INV-2026-118", "Training moves", "SPAM-BODY", "Viele Gr", "old photos", "ignore me"}
)


class PullTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.staging = Path(self.tmp.name) / "staging"

    def tearDown(self):
        self.tmp.cleanup()

    def full_at(self, state, staging=None, now=NOW):
        a, svc = api(state)
        return gmail_pull.run_pull(a, staging or self.staging, now=now), svc

    # -- the full pull ------------------------------------------------------

    def test_full_pull_normalises_every_non_spam_message(self):
        summary, svc = self.full_at("s1")
        export = load_export(summary["run_dir"])
        msgs = by_id(export["messages"])
        self.assertEqual(sorted(msgs), ["18f0000000000001", "18f0000000000002", "18f0000000000003", "18f0000000000005"])
        self.assertEqual(export["mode"], "full")
        self.assertEqual(export["history_id"], "1002")
        self.assertEqual(export["deleted_ids"], [])
        self.assertGreater(svc.calls.count("messages.list"), 1, "the listing paginates")

        m1 = msgs["18f0000000000001"]
        self.assertEqual(set(m1), {"id", "threadId", "date", "from", "to", "cc", "subject", "labels", "text", "attachments"})
        self.assertEqual(m1["subject"], "Möte på fredag")
        self.assertEqual(m1["text"], "Hej! Ses vi på fredag kl 10? /Anna")
        self.assertEqual(m1["date"], "2026-10-30T08:00:00Z")
        self.assertEqual(m1["labels"], ["IMPORTANT", "INBOX"])
        self.assertIsNone(m1["cc"])

        m2 = msgs["18f0000000000002"]
        self.assertEqual(m2["text"], "Invoice INV-2026-118 is attached. Total: 49.00 EUR.", "text/plain wins over its html twin")
        self.assertEqual(m2["cc"], "accounts@example.com")
        self.assertEqual(m2["attachments"], [{"name": "INV-2026-118.pdf", "mime": "application/pdf", "size": 18342, "part_id": "1"}])

        m3 = msgs["18f0000000000003"]
        self.assertEqual(m3["text"], "October\n\nTraining moves to Tuesday & Thursday.")
        self.assertNotIn("track()", m3["text"])
        self.assertNotIn("color:red", m3["text"])

        raw = (Path(summary["run_dir"]) / gmail_pull.EXPORT_NAME).read_text("utf-8")
        for absent in ("SNIPPET-NOT-EXPORTED", "ANGjdJ-ATTACHMENT-ID-NOT-FETCHED", "SPAM-SUBJECT"):
            self.assertNotIn(absent, raw)

    def test_charset_is_honoured(self):
        summary, _ = self.full_at("s2")
        m6 = by_id(load_export(summary["run_dir"])["messages"])["18f0000000000006"]
        self.assertEqual(m6["text"], "Viele Grüße aus München, Jürgen")
        self.assertEqual(m6["from"], "Jürgen Groß <jg@example.de>")

    def test_manifest_is_what_lake_ingest_loads(self):
        summary, _ = self.full_at("s1")
        manifest = json.loads((Path(summary["run_dir"]) / gmail_pull.MANIFEST_NAME).read_text("utf-8"))
        self.assertEqual(manifest["dataset_id"], "gmail")
        self.assertEqual(manifest["records"], [{"path": "messages.json", "mime": "application/json", "kind": "message_export", "sensitivity": "high"}])
        sys.path.insert(0, str(REPO / "scripts"))
        try:
            import lake_ingest
        except ImportError as exc:  # pragma: no cover - the image carries lake_ingest's imports or not
            self.skipTest(f"lake_ingest not importable here: {exc}")
        loaded = lake_ingest.load_manifest(str(Path(summary["run_dir"]) / gmail_pull.MANIFEST_NAME))
        self.assertEqual(loaded["records"][0]["kind"], "message_export")
        self.assertEqual(loaded["records"][0]["declared_sensitivity"], "high")
        self.assertTrue(os.path.exists(loaded["records"][0]["resolved_path"]))
        self.assertTrue(lake_ingest.manifest_needs_kek(loaded))

    def test_export_is_the_shape_the_explorer_parses(self):
        summary, _ = self.full_at("s1")
        parsed = json.loads((Path(summary["run_dir"]) / gmail_pull.EXPORT_NAME).read_bytes())
        self.assertIsInstance(parsed.get("messages"), list)
        for entry in parsed["messages"]:
            for key in ("from", "text", "date"):  # aspirant-explorer _MESSAGE_KEYS first hits
                self.assertIn(key, entry)

    # -- the acceptance -----------------------------------------------------

    def test_full_then_incremental_equals_a_fresh_full_pull(self):
        s1, _ = self.full_at("s1")
        state_s1 = by_id(load_export(s1["run_dir"])["messages"])

        a, svc = api("s2", history=FIXTURE["history_s1_to_s2"])
        inc = gmail_pull.run_pull(a, self.staging, now=LATER)
        self.assertEqual(inc["mode"], "incremental")
        self.assertNotIn("messages.list", svc.calls, "an incremental run never lists the mailbox")
        self.assertGreater(svc.calls.count("history.list"), 1, "the history paginates")
        delta = load_export(inc["run_dir"])
        self.assertEqual(delta["base_history_id"], "1002")
        self.assertEqual(delta["history_id"], "1008")
        self.assertEqual(sorted(m["id"] for m in delta["messages"]), ["18f0000000000002", "18f0000000000006"])
        self.assertEqual(delta["deleted_ids"], ["18f0000000000003", "18f0000000000005", "18f0000000000007"])

        replayed = gmail_pull.apply_delta(state_s1, delta)
        fresh, _ = self.full_at("s2", staging=Path(self.tmp.name) / "fresh")
        fresh_state = by_id(load_export(fresh["run_dir"])["messages"])
        self.assertEqual(sorted(replayed), sorted(fresh_state))
        for mid in fresh_state:
            self.assertEqual(gmail_pull.canonical_json(replayed[mid]), gmail_pull.canonical_json(fresh_state[mid]), mid)
        self.assertEqual(json.loads((self.staging / "state.json").read_text())["history_id"], "1008")

    def test_expired_history_falls_back_to_a_full_pull(self):
        self.staging.mkdir(parents=True)
        (self.staging / "state.json").write_text(json.dumps({"history_id": "800"}))
        a, svc = api("s2", history=FIXTURE["history_s1_to_s2"])
        summary = gmail_pull.run_pull(a, self.staging, now=NOW)
        self.assertEqual((summary["mode"], summary["fallback"]), ("full", "history_expired"))
        self.assertIn("history.list", svc.calls)
        fresh, _ = self.full_at("s2", staging=Path(self.tmp.name) / "fresh")
        self.assertEqual(load_export(summary["run_dir"])["messages"], load_export(fresh["run_dir"])["messages"])

    def test_no_change_writes_no_export_but_advances_state(self):
        self.full_at("s2")
        a, _ = api("s2", history=FIXTURE["history_s1_to_s2"])
        summary = gmail_pull.run_pull(a, self.staging, now=LATER)
        self.assertIsNone(summary["run_dir"])
        self.assertIn("no change", gmail_pull.render_summary(summary))
        self.assertEqual(len(list((self.staging / "runs").iterdir())), 1, "only the first run's directory")

    # -- the commit order ---------------------------------------------------

    def test_a_crash_before_the_run_is_complete_keeps_the_history_id(self):
        self.full_at("s1")
        a, _ = api("s2", history=FIXTURE["history_s1_to_s2"])
        with mock.patch.object(gmail_pull, "build_manifest", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                gmail_pull.run_pull(a, self.staging, now=LATER)
        self.assertEqual(json.loads((self.staging / "state.json").read_text())["history_id"], "1002")
        finals = [p.name for p in (self.staging / "runs").iterdir() if not p.name.startswith(".")]
        self.assertEqual(len(finals), 1, "no manifest-bearing directory for the failed run")
        a, _ = api("s2", history=FIXTURE["history_s1_to_s2"])
        retry = gmail_pull.run_pull(a, self.staging, now=LATER)
        self.assertEqual(load_export(retry["run_dir"])["base_history_id"], "1002", "the retry repeats the same window")
        self.assertFalse(list((self.staging / "runs").glob(".*.partial")))

    def test_files_are_private(self):
        summary, _ = self.full_at("s1")
        run = Path(summary["run_dir"])
        for path in (run / gmail_pull.EXPORT_NAME, run / gmail_pull.MANIFEST_NAME, self.staging / "state.json"):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600, path)
        for path in (self.staging, self.staging / "runs", run):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700, path)

    # -- the command --------------------------------------------------------

    def _cmd(self, env, attachments=False, **patches):
        out, err = io.StringIO(), io.StringIO()
        secrets = Path(self.tmp.name) / "secrets"
        with mock.patch.dict(os.environ, env, clear=False), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            with contextlib.ExitStack() as stack:
                for name, value in patches.items():
                    stack.enter_context(mock.patch.object(gmail_pull, name, value))
                args = mock.Mock(full=False, attachments=attachments)
                code = gmail_pull.cmd_pull(args, staging=self.staging, secrets_dir=secrets)
        return code, out.getvalue() + err.getvalue()

    def _store_token(self, kek: bytes):
        gmail_auth.write_token(
            {
                "refresh_token": "1//PULLTEST-REFRESH-TOKEN-NOT-REAL",
                "client_id": "123-pulltest.apps.googleusercontent.com",
                "client_secret": "GOCSPX-PULLTEST-NOT-REAL",
                "token_uri": "https://oauth2.googleapis.com/token",
                "scopes": [gmail_auth.SCOPE],
            },
            kek, 1, Path(self.tmp.name) / "secrets",
        )

    def test_refusals_write_nothing(self):
        kek = os.urandom(32)
        env = {"LAKE_KEK_HEX": kek.hex(), "LAKE_KEK_FINGERPRINT": ""}

        code, text = self._cmd({"LAKE_KEK_HEX": "not-hex", "LAKE_KEK_FINGERPRINT": ""})
        self.assertEqual(code, gmail_auth.EXIT_KEK, text)

        code, text = self._cmd(env)
        self.assertEqual(code, gmail_auth.EXIT_NO_TOKEN, text)

        self._store_token(kek)

        def refused(_creds):
            raise RuntimeError("('invalid_grant: Token has been expired or revoked.', ...)")

        code, text = self._cmd(env, _refresh=refused)
        self.assertEqual(code, gmail_auth.EXIT_RECONSENT, text)
        self.assertIn(gmail_auth.RECONSENT_LINE, text)

        code, text = self._cmd({"LAKE_KEK_HEX": os.urandom(32).hex(), "LAKE_KEK_FINGERPRINT": ""})
        self.assertEqual(code, gmail_auth.EXIT_KEK, "a different KEK does not open the token: " + text)

        self.assertFalse(self.staging.exists() and any(self.staging.iterdir()), "no refusal writes to staging")

    def test_a_run_through_the_command_logs_counts_only(self):
        kek = os.urandom(32)
        env = {"LAKE_KEK_HEX": kek.hex(), "LAKE_KEK_FINGERPRINT": ""}
        self._store_token(kek)
        ok = lambda _creds: None  # noqa: E731
        code, text = self._cmd(env, _refresh=ok, _build_api=lambda _c: api("s1")[0])
        self.assertEqual(code, 0, text)
        a, _ = api("s2", history=FIXTURE["history_s1_to_s2"])
        code2, text2 = self._cmd(env, _refresh=ok, _build_api=lambda _c: a)
        self.assertEqual(code2, 0, text2)
        logs = text + text2
        self.assertIn("mode=full", logs)
        self.assertIn("mode=incremental", logs)
        for secret in SECRET_STRINGS + ["PULLTEST-REFRESH-TOKEN", "GOCSPX-PULLTEST"]:
            self.assertNotIn(secret, logs)

    def test_no_room_for_attachments_exits_8_and_writes_nothing(self):
        kek = os.urandom(32)
        env = {"LAKE_KEK_HEX": kek.hex(), "LAKE_KEK_FINGERPRINT": ""}
        self._store_token(kek)
        with mock.patch.object(gmail_pull.shutil, "disk_usage", return_value=mock.Mock(free=1000)):
            code, text = self._cmd(env, attachments=True, _refresh=lambda _c: None, _build_api=lambda _c: api("s1")[0])
        self.assertEqual(code, gmail_pull.EXIT_NO_SPACE, text)
        self.assertIn("refused: 1 attachment part(s) to fetch", text)
        self.assertFalse((self.staging / gmail_pull.STATE_NAME).exists())
        self.assertFalse((self.staging / "runs").exists() and any((self.staging / "runs").iterdir()))

    def test_api_errors_exit_4_and_keep_the_history_id(self):
        def failing(name, status):
            def call(*_a, **_k):
                def boom():
                    raise http_error(status)
                return _Req(boom, [], name)
            return call

        self.full_at("s1")
        a, svc = api("s2")
        svc.getProfile = failing("getProfile", 500)
        with self.assertRaises(gmail_pull.PullError):
            gmail_pull.run_pull(a, self.staging, force_full=True, now=LATER)

        a, svc = api("s2")
        messages = svc.messages()
        messages.list = failing("messages.list", 503)
        svc.messages = lambda: messages
        kek = os.urandom(32)
        self._store_token(kek)
        env = {"LAKE_KEK_HEX": kek.hex(), "LAKE_KEK_FINGERPRINT": ""}
        args = mock.Mock(full=True)
        out = io.StringIO()
        with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(out), contextlib.redirect_stderr(out), \
                mock.patch.object(gmail_pull, "_refresh", lambda _c: None), mock.patch.object(gmail_pull, "_build_api", lambda _c: a):
            code = gmail_pull.cmd_pull(args, staging=self.staging, secrets_dir=Path(self.tmp.name) / "secrets")
        self.assertEqual(code, gmail_auth.EXIT_TRANSPORT, out.getvalue())
        self.assertIn("messages.list answered 503", out.getvalue())
        self.assertNotIn("Traceback", out.getvalue())
        self.assertEqual(json.loads((self.staging / "state.json").read_text())["history_id"], "1002")

    def test_a_second_pull_is_refused_while_one_holds_the_lock(self):
        kek = os.urandom(32)
        env = {"LAKE_KEK_HEX": kek.hex(), "LAKE_KEK_FINGERPRINT": ""}
        self._store_token(kek)
        with gmail_pull._Lock(self.staging):
            code, text = self._cmd(env, _refresh=lambda _c: None, _build_api=lambda _c: api("s1")[0])
        self.assertEqual(code, gmail_pull.EXIT_LOCKED, text)
        self.assertIsNone(gmail_pull.read_state(self.staging))



# --- #11344: Google's reason, pacing under the per-user limit, progress -----

# --- attachment content (#11557, security c75385 on #11557) ------------------

# Invented names, chosen to be hostile (a path) and personal (an invented
# person's name): neither may reach anything but the sealed export (A1).
PATH_NAME = "../../x"
PERSON_NAME = "Erika Mustermann Kontoauszug.pdf"
PERSON_BYTES = synthetic_bytes(4000, b"%PDF-1.4 synthetic statement\n")
INLINE_BYTES = synthetic_bytes(700, b"GIF89a synthetic\n")


def attachment_message(mid: str, parts: list[dict]) -> dict:
    return {
        "id": mid,
        "threadId": mid,
        "labelIds": ["INBOX"],
        "internalDate": "1793448000000",
        "payload": {
            "partId": "",
            "mimeType": "multipart/mixed",
            "headers": [{"name": "Subject", "value": "synthetic attachments"}, {"name": "From", "value": "a@example.test"}],
            "body": {"size": 0},
            "parts": [{"partId": "0", "mimeType": "text/plain", "filename": "", "body": {"size": 4, "data": b64url(b"body")}}]
            + parts,
        },
    }


class AttachmentTest(unittest.TestCase):
    """The attachment phase: off by default, on with `attachments=True`."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.staging = Path(self.tmp.name) / "staging"
        self.out = io.StringIO()

    def tearDown(self):
        self.tmp.cleanup()

    def api(self, state="s1", extra=()):
        svc = FakeService(state)
        for message, bodies in extra:
            svc.mail[message["id"]] = message
            svc.attachment_bodies.update(bodies)
        return gmail_pull.GmailApi(svc, progress=gmail_pull.Progress(out=self.out)), svc

    def pull(self, a, attachments=True, now=NOW, **kw):
        kw.setdefault("disk_free", lambda path: 10**12)
        return gmail_pull.run_pull(a, self.staging, now=now, attachments=attachments, **kw)

    def hostile(self):
        return attachment_message(
            "18f00000000000a1",
            [
                {"partId": "1", "mimeType": "Application/PDF; name=x", "filename": PERSON_NAME,
                 "body": {"size": len(PERSON_BYTES), "attachmentId": "ATT-PERSON"}},
                {"partId": "2", "mimeType": "image/gif", "filename": PATH_NAME,
                 "body": {"size": len(INLINE_BYTES), "data": b64url(INLINE_BYTES)}},
            ],
        ), {"ATT-PERSON": PERSON_BYTES}

    def test_by_default_no_content_is_fetched(self):
        a, svc = self.api()
        summary = self.pull(a, attachments=False)
        self.assertNotIn("messages.attachments.get", svc.calls)
        run = Path(summary["run_dir"])
        self.assertFalse((run / gmail_pull.ATTACHMENTS_DIR).exists())
        self.assertFalse((run / gmail_pull.LINKS_NAME).exists())
        manifest = json.loads((run / gmail_pull.MANIFEST_NAME).read_text("utf-8"))
        self.assertEqual([r["kind"] for r in manifest["records"]], ["message_export"])
        self.assertNotIn("att_fetched", summary)

    def test_a_fetched_part_is_a_blob_named_by_its_hash_with_a_link_and_a_high_record(self):
        a, svc = self.api()
        summary = self.pull(a)
        self.assertEqual(svc.calls.count("messages.attachments.get"), 1)
        data = svc.attachment_bodies[FIXTURE_ATTACHMENT_ID]
        digest = hashlib.sha256(data).hexdigest()
        run = Path(summary["run_dir"])
        blob = run / gmail_pull.ATTACHMENTS_DIR / digest
        self.assertEqual(blob.read_bytes(), data)
        self.assertEqual(stat.S_IMODE(blob.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((run / gmail_pull.ATTACHMENTS_DIR).stat().st_mode), 0o700)
        links = json.loads((run / gmail_pull.LINKS_NAME).read_text("utf-8"))
        self.assertEqual(links, {"links": [{"message_id": "18f0000000000002", "part_id": "1", "sha256": digest}], "refused": []})
        manifest = json.loads((run / gmail_pull.MANIFEST_NAME).read_text("utf-8"))
        self.assertEqual(
            manifest["records"][1],
            {"path": f"attachments/{digest}", "mime": "application/pdf", "kind": "message_attachment", "sensitivity": "high"},
        )
        self.assertEqual(
            (summary["att_parts"], summary["att_fetched"], summary["att_blobs"], summary["att_bytes"]), (1, 1, 1, len(data))
        )
        self.assertFalse((self.staging / gmail_pull.LINKED_DIR).exists(), "the pull never marks a part linked")
        # The fetch handle is still never written anywhere.
        for path in self.staging.rglob("*"):
            if path.is_file():
                self.assertNotIn(FIXTURE_ATTACHMENT_ID.encode(), path.read_bytes(), path.name)

    def test_the_only_gmail_calls_are_the_four_reads_and_attachments_get(self):
        message, bodies = self.hostile()
        a, svc = self.api(extra=[(message, bodies)])
        self.pull(a)
        a2, svc2 = self.api("s2")
        svc2.records = FIXTURE["history_s1_to_s2"]
        self.pull(a2, now=LATER)
        allowed = {"getProfile", "messages.list", "messages.get", "history.list", "messages.attachments.get"}
        self.assertLessEqual(set(svc.calls) | set(svc2.calls), allowed)
        self.assertIn("messages.attachments.get", svc.calls)

    def commit_links(self, summary):
        """What the wrapper does once the run's links are in the lake."""
        linked = self.staging / gmail_pull.LINKED_DIR
        linked.mkdir(mode=0o700, exist_ok=True)
        os.replace(Path(summary["run_dir"]) / gmail_pull.LINKS_NAME, linked / f"{summary['run_id']}.json")

    def test_a_part_whose_links_were_not_committed_is_fetched_again(self):
        a, _ = self.api()
        self.pull(a)
        a2, svc2 = self.api()
        summary = self.pull(a2, now=LATER, force_full=True)
        self.assertEqual(svc2.calls.count("messages.attachments.get"), 1)
        self.assertEqual((summary["att_already"], summary["att_fetched"]), (0, 1))

    def test_a_part_whose_links_were_committed_is_not_fetched_again(self):
        a, _ = self.api()
        self.commit_links(self.pull(a))
        a2, svc2 = self.api()
        summary = self.pull(a2, now=LATER, force_full=True)
        self.assertNotIn("messages.attachments.get", svc2.calls)
        self.assertEqual((summary["att_already"], summary["att_fetched"]), (1, 0))
        self.assertFalse((Path(summary["run_dir"]) / gmail_pull.ATTACHMENTS_DIR).exists())

    def test_the_file_name_reaches_only_the_sealed_export(self):
        message, bodies = self.hostile()
        a, _ = self.api(extra=[(message, bodies)])
        summary = self.pull(a)
        rendered = gmail_pull.render_summary(summary)
        names = [PATH_NAME, PERSON_NAME, "Mustermann"]
        export = Path(summary["run_dir"]) / gmail_pull.EXPORT_NAME
        self.assertIn(PERSON_NAME.encode("utf-8"), export.read_bytes(), "the export keeps the name")
        for path in self.staging.rglob("*"):
            for name in names:
                self.assertNotIn(name, str(path.relative_to(self.staging)))
            if path.is_file() and path != export:
                for name in names:
                    self.assertNotIn(name.encode("utf-8"), path.read_bytes(), path.name)
        for text in (rendered, self.out.getvalue()):
            for name in names:
                self.assertNotIn(name, text)
        self.assertEqual(summary["att_fetched"], 3)

    def test_refusals_are_named_by_id_and_reason_and_a_shared_blob_is_stored_once(self):
        same = synthetic_bytes(900, b"same synthetic\n")
        message = attachment_message(
            "18f00000000000a2",
            [
                {"partId": "1", "mimeType": "application/pdf", "filename": "big.pdf",
                 "body": {"size": gmail_pull.ATTACHMENT_CAP + 1, "attachmentId": "ATT-BIG"}},
                {"partId": "2", "mimeType": "application/pdf", "filename": "short.pdf",
                 "body": {"size": 5000, "attachmentId": "ATT-SHORT"}},
                {"partId": "3", "mimeType": "image/png", "filename": "a.png", "body": {"size": 900, "attachmentId": "ATT-SAME-1"}},
                {"partId": "4", "mimeType": "image/png", "filename": "b.png", "body": {"size": 900, "attachmentId": "ATT-SAME-2"}},
            ],
        )
        bodies = {"ATT-SHORT": synthetic_bytes(4999), "ATT-SAME-1": same, "ATT-SAME-2": same}
        a, svc = self.api(extra=[(message, bodies)])
        summary = self.pull(a)
        # The over-cap part is never fetched; its three siblings and the fixture's PDF are.
        self.assertEqual(svc.calls.count("messages.attachments.get"), 4)
        links = json.loads((Path(summary["run_dir"]) / gmail_pull.LINKS_NAME).read_text("utf-8"))
        self.assertEqual(
            links["refused"],
            [
                {"message_id": "18f00000000000a2", "part_id": "1", "reason": "over_cap"},
                {"message_id": "18f00000000000a2", "part_id": "2", "reason": "size_mismatch"},
            ],
        )
        shared = [link for link in links["links"] if link["message_id"] == "18f00000000000a2"]
        self.assertEqual([link["part_id"] for link in shared], ["3", "4"])
        self.assertEqual(shared[0]["sha256"], shared[1]["sha256"])
        self.assertEqual(summary["att_blobs"], 2)
        self.assertEqual(summary["att_refused_parts"], "18f00000000000a2/1:over_cap,18f00000000000a2/2:size_mismatch")
        self.assertNotIn("big.pdf", gmail_pull.render_summary(summary))
        self.commit_links(summary)
        seen = gmail_pull.read_seen(self.staging)
        self.assertEqual(seen, {"18f0000000000002/1", "18f00000000000a2/3", "18f00000000000a2/4"}, "a refused part is fetched again")

    def test_no_room_refuses_before_any_fetch_and_writes_nothing(self):
        a, _ = self.api()
        self.pull(a, attachments=False)
        state = (self.staging / gmail_pull.STATE_NAME).read_bytes()
        runs = sorted(p.name for p in (self.staging / "runs").iterdir())
        a2, svc2 = self.api()
        with self.assertRaises(gmail_pull.NoSpaceError) as caught:
            self.pull(a2, now=LATER, force_full=True, disk_free=lambda p: 1000)
        self.assertIn(f"1 attachment part(s) to fetch, {FIXTURE_ATTACHMENT_SIZE} bytes reported", str(caught.exception))
        self.assertIn("attachments: 1 part(s) to fetch", self.out.getvalue(), "the estimate is printed first")
        self.assertNotIn("messages.attachments.get", svc2.calls)
        self.assertEqual((self.staging / gmail_pull.STATE_NAME).read_bytes(), state)
        self.assertEqual(sorted(p.name for p in (self.staging / "runs").iterdir()), runs)

    def test_a_failed_fetch_leaves_no_clear_bytes_and_keeps_the_history_id(self):
        message, bodies = self.hostile()
        a, svc = self.api(extra=[(message, bodies)])
        real = svc.attachment_bodies

        class Failing(dict):
            def __contains__(self, key):
                if key == "ATT-PERSON":
                    raise http_error(500)
                return key in real

            def __getitem__(self, key):
                return real[key]

        svc.attachment_bodies = Failing()
        with self.assertRaises(gmail_pull.PullError):
            self.pull(a)
        self.assertEqual(svc.calls.count("messages.attachments.get"), 2, "the fixture's PDF was written first")
        self.assertFalse((self.staging / gmail_pull.STATE_NAME).exists())
        self.assertEqual(list((self.staging / "runs").iterdir()), [])

    def test_the_type_is_the_declared_one_normalised_as_the_explorer_does(self):
        self.assertEqual(gmail_pull.normalize_mime("Application/PDF; name=x"), "application/pdf")
        self.assertEqual(gmail_pull.normalize_mime(" image/svg+xml "), "image/svg+xml")
        self.assertEqual(gmail_pull.normalize_mime("text/html, image/png"), "application/octet-stream")
        self.assertEqual(gmail_pull.normalize_mime(""), "application/octet-stream")
        self.assertEqual(gmail_pull.normalize_mime(None), "application/octet-stream")
        message, bodies = self.hostile()
        a, _ = self.api(extra=[(message, bodies)])
        summary = self.pull(a)
        manifest = json.loads((Path(summary["run_dir"]) / gmail_pull.MANIFEST_NAME).read_text("utf-8"))
        mimes = sorted(r["mime"] for r in manifest["records"] if r["kind"] == "message_attachment")
        self.assertEqual(mimes, ["application/pdf", "application/pdf", "image/gif"])
        self.assertTrue(all(r["sensitivity"] == "high" for r in manifest["records"]))


def google_error(status: int, reason: str, message: str) -> HttpError:
    body = {"error": {"code": status, "message": message, "errors": [{"reason": reason, "message": message}]}}
    return HttpError(httplib2.Response({"status": status}), json.dumps(body).encode())


class FakeClock:
    """time.monotonic and time.sleep for the pacer, with nothing slept."""

    def __init__(self):
        self.now = 1000.0
        self.slept = []

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.now += seconds


def failing_gets(svc, errors):
    """messages.get raises the next error from `errors` (or each time, if it is
    a single exception), then answers normally once the list is used up."""
    pending = list(errors) if isinstance(errors, list) else None
    real = svc.messages

    class Messages:
        def __init__(self):
            self.inner = real()

        def list(self, *a, **k):
            return self.inner.list(*a, **k)

        def get(self, userId, id, format):
            ok = self.inner.get(userId, id, format)

            def answer():
                if pending is None:
                    raise errors
                if pending:
                    raise pending.pop(0)
                return ok.fn()

            return _Req(answer, svc.calls, "messages.get")

    svc.messages = lambda: Messages()


class PacingAndReasonTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.staging = Path(self.tmp.name) / "staging"
        self.kek = os.urandom(32)
        gmail_auth.write_token(
            {
                "refresh_token": "1//PULLTEST-REFRESH-TOKEN-NOT-REAL",
                "client_id": "123-pulltest.apps.googleusercontent.com",
                "client_secret": "GOCSPX-PULLTEST-NOT-REAL",
                "token_uri": "https://oauth2.googleapis.com/token",
                "scopes": [gmail_auth.SCOPE],
            },
            self.kek, 1, Path(self.tmp.name) / "secrets",
        )

    def tearDown(self):
        self.tmp.cleanup()

    def run_cmd(self, api_obj):
        out = io.StringIO()
        env = {"LAKE_KEK_HEX": self.kek.hex(), "LAKE_KEK_FINGERPRINT": ""}
        with mock.patch.dict(os.environ, env), contextlib.redirect_stdout(out), contextlib.redirect_stderr(out), \
                mock.patch.object(gmail_pull, "_refresh", lambda _c: None), \
                mock.patch.object(gmail_pull, "_build_api", lambda _c: api_obj):
            code = gmail_pull.cmd_pull(mock.Mock(full=True), staging=self.staging, secrets_dir=Path(self.tmp.name) / "secrets")
        return code, out.getvalue()

    def test_a_rate_limit_failure_names_googles_reason_and_the_progress(self):
        svc = FakeService("s1")
        failing_gets(svc, google_error(403, "rateLimitExceeded", "Rate Limit Exceeded"))
        clock = FakeClock()
        code, text = self.run_cmd(gmail_pull.GmailApi(svc, sleep=clock.sleep))
        self.assertEqual(code, gmail_auth.EXIT_TRANSPORT, text)
        self.assertIn("messages.get answered 403 reason=rateLimitExceeded", text)
        self.assertIn('("Rate Limit Exceeded")', text)
        listed = len([m for m in FIXTURE["s1"]["messages"] if not gmail_pull.EXCLUDED_LABELS.intersection(m["labelIds"])])
        self.assertIn(f"listed={listed} fetched=0 first_get=yes", text)
        self.assertIn("the stored history id is unchanged", text)
        # It waited out the window before giving up: 60, 120, 240, then 300s
        # steps, never past 30 minutes in all.
        self.assertEqual(clock.slept[:4], [60, 120, 240, 300])
        self.assertLessEqual(sum(clock.slept), gmail_pull.RATE_WAIT_GIVE_UP)
        self.assertIn("after waiting", text)

    def test_a_forbidden_failure_names_its_reason_and_does_not_wait(self):
        svc = FakeService("s1")
        failing_gets(svc, google_error(403, "forbidden", "Forbidden"))
        clock = FakeClock()
        code, text = self.run_cmd(gmail_pull.GmailApi(svc, sleep=clock.sleep))
        self.assertEqual(code, gmail_auth.EXIT_TRANSPORT, text)
        self.assertIn("messages.get answered 403 reason=forbidden", text)
        self.assertIn('("Forbidden")', text)
        self.assertIn("first_get=yes", text)
        self.assertEqual(clock.slept, [], "a refusal that is not a rate limit is not waited on")

    def test_googles_message_is_printed_without_ids_or_addresses(self):
        svc = FakeService("s1")
        mid = sorted(svc.mail)[0]
        failing_gets(svc, google_error(400, "invalidArgument", f"Invalid id {mid}1234567890ab for mara@example.se"))
        code, text = self.run_cmd(gmail_pull.GmailApi(svc, sleep=FakeClock().sleep))
        self.assertEqual(code, gmail_auth.EXIT_TRANSPORT, text)
        self.assertIn("reason=invalidArgument", text)
        self.assertNotIn("mara@example.se", text)
        self.assertNotIn(mid, text)
        self.assertIn("<address>", text)

    def test_one_rate_limit_waits_then_resumes_more_slowly(self):
        svc = FakeService("s1")
        failing_gets(svc, [google_error(429, "rateLimitExceeded", "slow down")])
        clock = FakeClock()
        out = io.StringIO()
        a = gmail_pull.paced_api(svc, units_per_minute=5100, clock=clock, sleep=clock.sleep, out=out)
        summary = gmail_pull.run_pull(a, self.staging, now=NOW)
        self.assertEqual(summary["mode"], "full")
        self.assertIn(60, clock.slept, "the refusal waited for the window")
        self.assertAlmostEqual(a.pacer.units_per_minute, 5100 * gmail_pull.SLOW_DOWN)
        self.assertIn("rate-limited (rateLimitExceeded); waiting 60s", out.getvalue())

    def test_the_pace_keeps_every_minute_under_the_user_limit(self):
        clock = FakeClock()
        pacer = gmail_pull.Pacer(gmail_pull.DEFAULT_UNITS_PER_MINUTE, clock=clock, sleep=clock.sleep)
        spent = []
        for i in range(300):
            cost = gmail_pull.UNIT_COST["messages.list" if i % 50 == 0 else "messages.get"]
            pacer.spend(cost)
            spent.append((clock(), cost))
        for start, _ in spent:
            window = sum(c for t, c in spent if start <= t < start + 60)
            self.assertLessEqual(window, gmail_pull.DEFAULT_UNITS_PER_MINUTE + gmail_pull.UNIT_COST["messages.get"])
            self.assertLess(window, gmail_pull.USER_UNITS_PER_MINUTE)
        # And the pace is used, not left far below: 300 calls at ~60 units take
        # about 300*60/5100 minutes.
        minutes = (spent[-1][0] - spent[0][0]) / 60
        self.assertGreater(minutes, 3.0)
        self.assertLess(minutes, 3.6)

    def test_the_env_override_cannot_raise_the_pace_past_the_limit(self):
        for raw, want in (("9000", 6000), ("3000", 3000), ("nonsense", 5100), ("", 5100), ("0", 60)):
            with mock.patch.dict(os.environ, {"GMAIL_UNITS_PER_MINUTE": raw}):
                self.assertEqual(gmail_pull.units_per_minute_from_env(), want, raw)

    def test_the_command_builds_a_paced_api(self):
        a = gmail_pull.paced_api(FakeService("s1"))
        self.assertIsNotNone(a.pacer)
        self.assertEqual(a.pacer.units_per_minute, gmail_pull.DEFAULT_UNITS_PER_MINUTE)

    def test_progress_lines_carry_counts_and_time_only(self):
        svc = FakeService("s1")
        clock = FakeClock()
        out = io.StringIO()
        a = gmail_pull.paced_api(svc, units_per_minute=600, clock=clock, sleep=clock.sleep, out=out)
        gmail_pull.run_pull(a, self.staging, now=NOW)
        lines = [l for l in out.getvalue().splitlines() if l]
        self.assertTrue(any("fetching: fetched 0/" in l for l in lines), lines)
        allowed = re.compile(
            r"^gmail pull: (listing|fetching): fetched \d+(/\d+ \(\d+%\)(, ~\d+h\d\dm left at \d+/min)?)?$"
        )
        for line in lines:
            self.assertRegex(line, allowed)
        for secret in SECRET_STRINGS + sorted(svc.mail):
            self.assertNotIn(secret, out.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
