#!/usr/bin/env python3
"""Gmail pull, on demand: full or incremental, into message_export files.

system_3 #8806-B1 (epic #8806). This program owns the Gmail API traffic and the
on-disk export shape, and nothing else. It does not encrypt for the lake (the
ingest runner does that, #8806-B2), and it stores no credential: the refresh
token is opened in memory with `gmail_auth.load_credentials`, which needs the
lake KEK, exactly as `gmail.sh status --check` does.

A run
-----
1. Refresh check first. A refused refresh token exits 3 with the re-consent
   line, rather than returning stale mail as if it were current.
2. If `state.json` holds a `history_id`, pull **incrementally**:
   `users.history.list` from that id, then `users.messages.get` (format full)
   for every message the history touched. Gmail keeps history for a limited
   time; a 404 means it has expired, and the run falls back to a full pull.
3. Otherwise, or with `--full`, pull **everything**: `users.getProfile` for the
   current history id (read BEFORE listing, so a message that arrives during the
   listing is replayed by the next run rather than missed), then
   `users.messages.list` and a `get` per message.
4. Write one export, `messages.json`, and the run manifest `lake_ingest.py`
   reads, into a run directory that is renamed into place only once both files
   are complete. Then, and only then, write the new `history_id` to
   `state.json`. A run that dies at any earlier point leaves the stored history
   id where it was, so the next run repeats the same window.

The export
----------
`{"messages": [...], "deleted_ids": [...], ...}`: the shape the explorer's
`/api/assets/{sha}/messages` route parses (`from`, `text`, `date` are the keys
it reads first). One entry per message:
`id, threadId, date, from, to, cc, subject, labels, text, attachments`, where
`attachments` is metadata only (`name, mime, size`) until the security review
(#8806-D1) says otherwise.

A full export is the mailbox. An incremental export is a **delta**: the
messages added or changed since the stored history id, plus `deleted_ids` for
the ones that left (deleted, or moved to spam or trash). Applying a delta to
the previous full state gives exactly what a fresh full pull would give; that
equality is what `tests/gmail_pull_test.py` proves. Spam and trash are left out
on both paths. A delta with no change writes no export, and still advances the
history id.

What is never printed
---------------------
Counts and the run id only: never a subject, an address, a body or a token.

Exit codes: 0 ok; 2 KEK or envelope failure; 3 re-consent needed; 4 transport
or API error; 5 configuration refused; 6 no token stored; 7 another pull holds
the staging lock.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import html
import json
import os
import re
import shutil
import sys
from datetime import datetime, timezone
from email.message import Message
from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import gmail_auth  # noqa: E402  (puts scripts/kek on the path itself)

STAGING_DIR = Path(os.environ.get("GMAIL_STAGING_DIR", "/staging"))
EXPORT_NAME = "messages.json"
MANIFEST_NAME = "manifest.json"
STATE_NAME = "state.json"
DATASET_ID = "gmail"
SOURCE = "gmail:users/me"
EXPORT_FORMAT = "gmail-message-export/1"
# Messages carrying one of these are not part of the mailbox an export
# describes: messages.list leaves them out by default, and the incremental path
# has to agree, or the two would describe different mailboxes.
EXCLUDED_LABELS = frozenset({"SPAM", "TRASH"})
HISTORY_TYPES = ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"]
LIST_PAGE = 500
RETRIES = 5

EXIT_LOCKED = 7


class HistoryExpired(Exception):
    """users.history.list answered 404: the stored history id is too old."""


class PullError(Exception):
    """A Gmail API call failed for a reason other than a missing object."""


def _http_status(exc) -> int | None:
    resp = getattr(exc, "resp", None)
    status = getattr(resp, "status", None) or getattr(exc, "status_code", None)
    try:
        return int(status) if status is not None else None
    except (TypeError, ValueError):
        return None


class GmailApi:
    """The only code that talks to Google: four read-only calls.

    `service` is what `googleapiclient.discovery.build("gmail", "v1")` returns;
    the test passes a fake with the same call chain, so this wrapper (pagination
    arguments, the 404 mapping) is exercised as well, not mocked away.
    """

    def __init__(self, service):
        self._users = service.users()

    def _run(self, request):
        from googleapiclient.errors import HttpError  # lazy: only the image has it

        try:
            return request.execute(num_retries=RETRIES)
        except HttpError:
            raise
        except Exception as exc:  # noqa: BLE001 - transport errors carry no mail
            raise PullError(type(exc).__name__) from exc

    def profile(self) -> dict:
        return self._run(self._users.getProfile(userId="me"))

    def list_message_ids(self, page_token: str | None = None) -> dict:
        return self._run(
            self._users.messages().list(
                userId="me", maxResults=LIST_PAGE, pageToken=page_token, includeSpamTrash=False
            )
        )

    def get_message(self, message_id: str) -> dict | None:
        """The full message, or None if it no longer exists."""
        from googleapiclient.errors import HttpError

        try:
            return self._run(self._users.messages().get(userId="me", id=message_id, format="full"))
        except HttpError as exc:
            if _http_status(exc) == 404:
                return None
            raise PullError(f"messages.get answered {_http_status(exc)}") from exc

    def list_history(self, start_history_id: str, page_token: str | None = None) -> dict:
        from googleapiclient.errors import HttpError

        try:
            return self._run(
                self._users.history().list(
                    userId="me",
                    startHistoryId=start_history_id,
                    historyTypes=HISTORY_TYPES,
                    maxResults=LIST_PAGE,
                    pageToken=page_token,
                )
            )
        except HttpError as exc:
            if _http_status(exc) == 404:
                raise HistoryExpired(start_history_id) from exc
            raise PullError(f"history.list answered {_http_status(exc)}") from exc


# --- message normalisation ---------------------------------------------------

class _TextOfHtml(HTMLParser):
    """Visible text of an HTML body: no tags, no script or style content."""

    _SKIP = {"script", "style", "head", "title"}
    _BREAK = {"br", "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "table"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self._skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in self._SKIP:
            self._skip += 1
        elif tag in self._BREAK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in self._SKIP and self._skip:
            self._skip -= 1
        elif tag in self._BREAK:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(data)


def html_to_text(markup: str) -> str:
    parser = _TextOfHtml()
    parser.feed(markup)
    parser.close()
    text = html.unescape("".join(parser.parts))
    lines = [re.sub(r"[ \t\r\f\v]+", " ", line).strip() for line in text.split("\n")]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def _headers(part: dict) -> dict[str, str]:
    out: dict[str, str] = {}
    for header in part.get("headers") or []:
        name = (header.get("name") or "").lower()
        if name and name not in out:
            out[name] = header.get("value") or ""
    return out


def _charset(part: dict) -> str:
    content_type = _headers(part).get("content-type", "")
    if content_type:
        msg = Message()
        msg["content-type"] = content_type
        charset = msg.get_content_charset()
        if charset:
            return charset
    return "utf-8"


def _decode_body(part: dict) -> str:
    data = (part.get("body") or {}).get("data")
    if not data:
        return ""
    raw = base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))
    try:
        return raw.decode(_charset(part), errors="replace")
    except LookupError:  # an unknown charset name
        return raw.decode("utf-8", errors="replace")


def _walk(part: dict):
    yield part
    for child in part.get("parts") or []:
        yield from _walk(child)


def _is_attachment(part: dict) -> bool:
    return bool(part.get("filename")) or bool((part.get("body") or {}).get("attachmentId"))


def extract_text(payload: dict) -> str:
    """The message's text: its text/plain parts, else its text/html made plain."""
    plain, markup = [], []
    for part in _walk(payload):
        if _is_attachment(part):
            continue
        mime = (part.get("mimeType") or "").lower()
        if mime == "text/plain":
            plain.append(_decode_body(part))
        elif mime == "text/html":
            markup.append(_decode_body(part))
    if plain:
        return "\n".join(t.strip("\r\n") for t in plain).strip()
    if markup:
        return "\n".join(html_to_text(m) for m in markup).strip()
    return ""


def extract_attachments(payload: dict) -> list[dict]:
    """Metadata only (#8806-D1 decides whether content is ever pulled)."""
    out = []
    for part in _walk(payload):
        if part is payload or not _is_attachment(part):
            continue
        out.append(
            {
                "name": part.get("filename") or "",
                "mime": part.get("mimeType") or "application/octet-stream",
                "size": int((part.get("body") or {}).get("size") or 0),
            }
        )
    return out


def _iso_from_ms(internal_date) -> str | None:
    if internal_date in (None, ""):
        return None
    moment = datetime.fromtimestamp(int(internal_date) / 1000, tz=timezone.utc)
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize_message(message: dict) -> dict:
    payload = message.get("payload") or {}
    headers = _headers(payload)
    return {
        "id": message["id"],
        "threadId": message.get("threadId"),
        "date": _iso_from_ms(message.get("internalDate")),
        "from": headers.get("from"),
        "to": headers.get("to"),
        "cc": headers.get("cc"),
        "subject": headers.get("subject"),
        "labels": sorted(message.get("labelIds") or []),
        "text": extract_text(payload),
        "attachments": extract_attachments(payload),
    }


def is_excluded(message: dict) -> bool:
    return bool(EXCLUDED_LABELS.intersection(message.get("labelIds") or []))


# --- the two pulls -----------------------------------------------------------

def _pages(call):
    token = None
    while True:
        page = call(token)
        yield page
        token = page.get("nextPageToken")
        if not token:
            return


def full_pull(api: GmailApi) -> dict:
    history_id = str(api.profile()["historyId"])
    ids = [m["id"] for page in _pages(api.list_message_ids) for m in page.get("messages") or []]
    messages, counts = {}, {"listed": len(ids), "gone": 0, "excluded": 0}
    for message_id in ids:
        message = api.get_message(message_id)
        if message is None:
            counts["gone"] += 1
        elif is_excluded(message):
            counts["excluded"] += 1
        else:
            messages[message_id] = normalize_message(message)
    return {
        "mode": "full",
        "base_history_id": None,
        "history_id": history_id,
        "messages": [messages[k] for k in sorted(messages)],
        "deleted_ids": [],
        "counts": counts,
    }


def incremental_pull(api: GmailApi, start_history_id: str) -> dict:
    touched, deleted = set(), set()
    history_id = start_history_id
    records = 0
    for page in _pages(lambda token: api.list_history(start_history_id, token)):
        history_id = str(page.get("historyId") or history_id)
        for record in page.get("history") or []:
            records += 1
            for key in ("messagesAdded", "labelsAdded", "labelsRemoved"):
                for entry in record.get(key) or []:
                    touched.add(entry["message"]["id"])
            for entry in record.get("messagesDeleted") or []:
                deleted.add(entry["message"]["id"])
    messages, counts = {}, {"history_records": records, "touched": len(touched), "gone": 0, "excluded": 0}
    for message_id in sorted(touched - deleted):
        message = api.get_message(message_id)
        if message is None:
            counts["gone"] += 1
            deleted.add(message_id)
        elif is_excluded(message):
            counts["excluded"] += 1
            deleted.add(message_id)
        else:
            messages[message_id] = normalize_message(message)
    return {
        "mode": "incremental",
        "base_history_id": start_history_id,
        "history_id": history_id,
        "messages": [messages[k] for k in sorted(messages)],
        "deleted_ids": sorted(deleted),
        "counts": counts,
    }


def apply_delta(state: dict[str, dict], export: dict) -> dict[str, dict]:
    """The mailbox after `export`, given the mailbox before it (by message id).

    A full export replaces the state; a delta removes `deleted_ids` and then
    upserts its messages. This is the reading B2 and C1 give a run sequence,
    and the test's statement of "full and incremental agree".
    """
    out = {} if export["mode"] == "full" else dict(state)
    for message_id in export["deleted_ids"]:
        out.pop(message_id, None)
    for message in export["messages"]:
        out[message["id"]] = message
    return out


# --- writing a run -----------------------------------------------------------

def canonical_json(obj) -> bytes:
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _write_private(path: Path, data: bytes) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.chmod(path, 0o600)


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def read_state(staging: Path) -> dict | None:
    path = staging / STATE_NAME
    if not path.exists():
        return None
    return json.loads(path.read_text("utf-8"))


def write_state(staging: Path, history_id: str, run_id: str, now: datetime) -> None:
    tmp = staging / (STATE_NAME + ".tmp")
    body = {"history_id": history_id, "last_run": run_id, "updated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ")}
    _write_private(tmp, json.dumps(body, indent=1, sort_keys=True).encode("utf-8"))
    os.replace(tmp, staging / STATE_NAME)
    _fsync_dir(staging)


def build_manifest(run_id: str, export: dict) -> dict:
    """The source manifest `scripts/lake_ingest.py` loads (REAL_DATA_INGEST.md)."""
    return {
        "dataset_id": DATASET_ID,
        "source": f"{SOURCE} {export['mode']} run {run_id}",
        "records": [
            {
                "path": EXPORT_NAME,
                "mime": "application/json",
                "kind": "message_export",
                "sensitivity": "high",
            }
        ],
    }


def write_run(staging: Path, run_id: str, export: dict, now: datetime) -> Path:
    """Write the export and its manifest; the run dir appears only when complete."""
    runs = staging / "runs"
    runs.mkdir(mode=0o700, parents=True, exist_ok=True)
    partial = runs / f".{run_id}.partial"
    if partial.exists():
        shutil.rmtree(partial)
    partial.mkdir(mode=0o700)
    document = {
        "format": EXPORT_FORMAT,
        "mode": export["mode"],
        "base_history_id": export["base_history_id"],
        "history_id": export["history_id"],
        "pulled_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "messages": export["messages"],
        "deleted_ids": export["deleted_ids"],
    }
    _write_private(partial / EXPORT_NAME, canonical_json(document))
    _write_private(partial / MANIFEST_NAME, json.dumps(build_manifest(run_id, export), indent=1).encode("utf-8"))
    _fsync_dir(partial)
    final = runs / run_id
    os.rename(partial, final)
    _fsync_dir(runs)
    return final


def run_pull(api: GmailApi, staging: Path, *, force_full: bool = False, now: datetime | None = None) -> dict:
    """One pull, end to end. Returns a summary of counts (no mail content)."""
    now = now or datetime.now(timezone.utc)
    staging.mkdir(mode=0o700, parents=True, exist_ok=True)
    state = None if force_full else read_state(staging)
    fallback = None
    if state and state.get("history_id"):
        try:
            export = incremental_pull(api, str(state["history_id"]))
        except HistoryExpired:
            fallback = "history_expired"
            export = full_pull(api)
    else:
        export = full_pull(api)

    run_id = f"{now.strftime('%Y%m%dT%H%M%SZ')}-{export['mode']}"
    changed = bool(export["messages"] or export["deleted_ids"]) or export["mode"] == "full"
    run_dir = write_run(staging, run_id, export, now) if changed else None
    # Last, and only once the run directory is in place: the history id the
    # next run starts from.
    write_state(staging, export["history_id"], run_id, now)
    return {
        "run_id": run_id,
        "mode": export["mode"],
        "fallback": fallback,
        "exported": len(export["messages"]),
        "deleted": len(export["deleted_ids"]),
        "history": f"{export['base_history_id'] or '-'}->{export['history_id']}",
        "run_dir": str(run_dir) if run_dir else None,
        **{f"n_{k}": v for k, v in export["counts"].items()},
    }


def render_summary(summary: dict) -> str:
    parts = [f"{k}={v}" for k, v in summary.items() if v is not None and k != "run_dir"]
    line = "gmail pull: " + " ".join(parts)
    if summary.get("run_dir") is None:
        line += " (no change; nothing to ingest)"
    return line


# --- command line ------------------------------------------------------------

def _refresh(creds) -> None:
    from google.auth.transport.requests import Request  # lazy

    creds.refresh(Request())


def _build_api(creds) -> GmailApi:
    from googleapiclient.discovery import build  # lazy

    return GmailApi(build("gmail", "v1", credentials=creds, cache_discovery=False))


class _Lock:
    def __init__(self, staging: Path):
        self.path = staging / ".lock"
        self.handle = None

    def __enter__(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.handle = open(self.path, "a")
        try:
            fcntl.flock(self.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.handle.close()
            raise
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.handle, fcntl.LOCK_UN)
        self.handle.close()


def cmd_pull(args, staging: Path = STAGING_DIR, secrets_dir: Path | None = None) -> int:
    os.umask(0o077)
    try:
        kek, _version = gmail_auth._kek()
    except gmail_auth.kek_loader.KekLoadError as exc:
        print(f"refused: no usable KEK ({type(exc).__name__})", file=sys.stderr)
        return gmail_auth.EXIT_KEK
    try:
        creds = gmail_auth.load_credentials(kek, secrets_dir or gmail_auth.SECRETS_DIR)
    except FileNotFoundError:
        print("no token stored (run `scripts/gmail/gmail.sh consent`)", file=sys.stderr)
        return gmail_auth.EXIT_NO_TOKEN
    except gmail_auth.dek_envelope.EnvelopeError:
        print("KEK does not open the stored token (wrong key or tampered file)", file=sys.stderr)
        return gmail_auth.EXIT_KEK
    except gmail_auth.ConfigError as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return gmail_auth.EXIT_CONFIG
    code, line = gmail_auth.classify_refresh(lambda: _refresh(creds))
    if code != gmail_auth.EXIT_OK:
        print(line, file=sys.stderr)
        return code
    try:
        with _Lock(staging):
            summary = run_pull(_build_api(creds), staging, force_full=args.full)
    except BlockingIOError:
        print("another gmail pull holds the staging lock; try again when it ends", file=sys.stderr)
        return EXIT_LOCKED
    except PullError as exc:
        print(f"pull failed (transport or API): {exc}; the stored history id is unchanged", file=sys.stderr)
        return gmail_auth.EXIT_TRANSPORT
    print(render_summary(summary))
    return gmail_auth.EXIT_OK


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--full", action="store_true", help="ignore the stored history id and pull everything")
    args = parser.parse_args(argv)
    return cmd_pull(args)


if __name__ == "__main__":
    sys.exit(main())
