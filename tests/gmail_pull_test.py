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

import contextlib
import copy
import io
import json
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
        self.assertEqual(m2["attachments"], [{"name": "INV-2026-118.pdf", "mime": "application/pdf", "size": 18342}])

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

    def _cmd(self, env, **patches):
        out, err = io.StringIO(), io.StringIO()
        secrets = Path(self.tmp.name) / "secrets"
        with mock.patch.dict(os.environ, env, clear=False), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            with contextlib.ExitStack() as stack:
                for name, value in patches.items():
                    stack.enter_context(mock.patch.object(gmail_pull, name, value))
                code = gmail_pull.cmd_pull(mock.Mock(full=False), staging=self.staging, secrets_dir=secrets)
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
