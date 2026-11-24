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
`attachments` is each part's metadata: `name, mime, size, part_id`. The file
name lives here and nowhere else (security c75385 A1 on system_3 #11557): this
export is sealed at ingest.

Attachment content (system_3 #11557, security c75385 on #11557)
---------------------------------------------------------------
Off unless the run is given `--attachments`. Then, after the messages:

1. Plan. Every attachment part of the run's messages, less the ones already
   linked: the parts named in `attachments-linked/<run id>.json` under the
   staging directory, keyed by message id and part id (stable in Gmail: a
   message's content never changes). The pull never writes that directory.
   The wrapper moves a run's `links.json` there only once its links are in the
   lake, so a run whose link step did not finish is fetched again, which the
   ingest's content-address dedup and the link writer's ON CONFLICT DO NOTHING
   make harmless. A part whose reported size is over ATTACHMENT_CAP is not
   fetched.
2. Estimate, before any fetch (A5): parts and reported bytes to fetch, and the
   free space under the staging directory. If the bytes plus a margin do not
   fit, the run refuses (exit 8) and writes nothing, so the history id stays
   where it was and the next run repeats the window.
3. Fetch (A3): `users.messages.attachments.get` only, or the part's inline data
   when Gmail sent it with the message. No URL in a message is ever fetched.
   The call answers base64url JSON, so each part is in memory whole: the cap is
   the memory bound, and the bytes are not streamed. A part whose decoded
   length differs from the reported size is refused (A4).
4. Write (A1): `attachments/<sha256>` in the run directory, named by its hash,
   never by its file name. `links.json` holds `(message_id, part_id, sha256)`
   for each fetched part, and the refused parts by id and reason code. The
   manifest gains one `message_attachment` record per distinct blob, at
   `sensitivity=high` whatever its type (A7), with Gmail's declared type
   normalised as the explorer normalises it (A2). Nothing opens, parses or
   previews the bytes.

A full export is the mailbox. An incremental export is a **delta**: the
messages added or changed since the stored history id, plus `deleted_ids` for
the ones that left (deleted, or moved to spam or trash). Applying a delta to
the previous full state gives exactly what a fresh full pull would give; that
equality is what `tests/gmail_pull_test.py` proves. Spam and trash are left out
on both paths. A delta with no change writes no export, and still advances the
history id.

Pacing (system_3 #11344)
------------------------
Gmail charges each call in quota units against a per-user limit of 6,000 a
minute: `messages.get` with `format=full` costs 60, `messages.list` 5,
`history.list` 2, `getProfile` 1. The first real pull ran its gets serially at
about 16 ms each, far past 100 a minute, and was refused with 403s. Every call
now spends its cost from a budget of 5,100 units a minute (85% of the limit;
`GMAIL_UNITS_PER_MINUTE` lowers it, and nothing raises it past 6,000) before it
runs. A rate-limit refusal that outlasts the library's own retries waits for
the window to recover (60 s, doubling to 300 s), resumes at a slower pace, and
fails only after 30 minutes of waiting on one call.

What is never printed
---------------------
Counts, times and the run id only: never a subject, an address, a body, a
message id or a token. The one exception is an attachment part refused at
fetch, which the summary names by message id, part id and reason code, never by
file name or type (security c75385 A4, A8). A failure names the call, its HTTP
status and Google's reason code; Google's message is printed with anything shaped like an id or an
address redacted. While it runs, the pull prints its progress on stderr once a
minute: messages fetched of those listed, and the time left at the current pace.

Exit codes: 0 ok; 2 KEK or envelope failure; 3 re-consent needed; 4 transport
or API error; 5 configuration refused; 6 no token stored; 7 another pull holds
the staging lock; 8 the attachments to fetch do not fit the staging disk.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import html
import json
import os
import re
import shutil
import sys
import time
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

# Gmail API quota units per call (developers.google.com/workspace/gmail/api/
# reference/quota, as design read it for #11344): the per-user limit is 6,000
# units a minute, and a full get costs 60 of them.
UNIT_COST = {
    "getProfile": 1,
    "messages.list": 5,
    "messages.get": 60,
    "history.list": 2,
    "messages.attachments.get": 5,
}
USER_UNITS_PER_MINUTE = 6000
DEFAULT_UNITS_PER_MINUTE = 5100  # 85%: headroom under the per-user limit
RATE_LIMIT_REASONS = frozenset({"rateLimitExceeded", "userRateLimitExceeded"})
RATE_WAIT_FIRST = 60
RATE_WAIT_MAX = 300
RATE_WAIT_GIVE_UP = 30 * 60
SLOW_DOWN = 0.8
PROGRESS_EVERY = 60

EXIT_LOCKED = 7
EXIT_NO_SPACE = 8

# Attachment content (#11557, security c75385). The cap is Gmail's own limit on
# a received attachment, and the memory bound of one fetch (A4).
ATTACHMENT_CAP = 25 * 1024 * 1024
ATTACHMENTS_DIR = "attachments"
LINKS_NAME = "links.json"
LINKED_DIR = "attachments-linked"
ATTACHMENT_KIND = "message_attachment"
# Free space the attachment phase leaves: a tenth of what it fetches, and never
# less than this.
SPACE_MARGIN_MIN = 64 * 1024 * 1024
# The explorer's rule for a stored type (aspirant-explorer app/routes.py,
# `_content_type_and_disposition`): cut at ";", stripped, lower case, exactly
# one type/subtype. Anything else is application/octet-stream (A2).
_MIME_SHAPE = re.compile(r"^[a-z0-9.+-]+/[a-z0-9.+-]+$")
OCTET_STREAM = "application/octet-stream"


class HistoryExpired(Exception):
    """users.history.list answered 404: the stored history id is too old."""


class NoSpaceError(Exception):
    """The attachments a run would fetch do not fit the staging disk (A5).

    `str()` is counts and bytes only."""


class PullError(Exception):
    """A Gmail API call failed for a reason other than a missing object.

    `str()` is the failure line's middle: the call, its status, Google's reason
    code and (redacted) message, then the progress so far. Never mail content.
    """

    def __init__(self, detail: str, *, reason: str | None = None, progress: str | None = None):
        self.reason = reason
        self.progress = progress
        super().__init__(f"{detail}; {progress}" if progress else detail)


_ADDRESS = re.compile(r"[^\s\"'<>(),;:]+@[^\s\"'<>(),;:]+")
_ID_LIKE = re.compile(r"\b(?=[0-9A-Za-z_-]*\d)[0-9A-Za-z_-]{12,}\b")


def redact(text: str) -> str:
    """Google's error message, safe to print: no address, nothing shaped like
    a message or thread id, one line, at most 200 characters."""
    text = " ".join(str(text).split())
    text = _ADDRESS.sub("<address>", text)
    text = _ID_LIKE.sub("<id>", text)
    return text[:200]


def _google_error(exc) -> tuple[str | None, str | None]:
    """(reason, message) from an HttpError's JSON body, or (None, None)."""
    try:
        body = json.loads(getattr(exc, "content", b"").decode("utf-8", "replace"))
        error = body.get("error") or {}
    except (ValueError, AttributeError):
        return None, None
    if not isinstance(error, dict):
        return None, None
    reasons = [e.get("reason") for e in error.get("errors") or [] if isinstance(e, dict) and e.get("reason")]
    reason = reasons[0] if reasons else error.get("status")
    return (str(reason) if reason else None), (str(error["message"]) if error.get("message") else None)


class Pacer:
    """Spends quota units so no 60-second window holds more than the budget
    plus one call. Each call starts no earlier than the previous one's cost
    allows at `units_per_minute`; the clock and sleep are injected for tests."""

    def __init__(self, units_per_minute: float, clock=time.monotonic, sleep=time.sleep):
        self.units_per_minute = float(units_per_minute)
        self.clock, self.sleep = clock, sleep
        self._next = None

    def spend(self, units: int) -> None:
        now = self.clock()
        if self._next is None or self._next < now:
            self._next = now
        if self._next > now:
            self.sleep(self._next - now)
        self._next += units * 60.0 / self.units_per_minute

    def slow_down(self) -> None:
        self.units_per_minute *= SLOW_DOWN


def units_per_minute_from_env() -> int:
    raw = os.environ.get("GMAIL_UNITS_PER_MINUTE", "")
    try:
        value = int(raw) if raw else DEFAULT_UNITS_PER_MINUTE
    except ValueError:
        value = DEFAULT_UNITS_PER_MINUTE
    return max(60, min(value, USER_UNITS_PER_MINUTE))


class Progress:
    """Counts only. Prints on stderr at most once per PROGRESS_EVERY seconds,
    and at each phase change."""

    def __init__(self, clock=time.monotonic, out=None, pacer: Pacer | None = None):
        self.clock, self.out, self.pacer = clock, out, pacer
        self.phase = "starting"
        self.listed = None
        self.fetched = 0
        self._last = None

    def counts(self) -> str:
        listed = "?" if self.listed is None else self.listed
        return f"listed={listed} fetched={self.fetched} first_get={'yes' if self.fetched == 0 else 'no'}"

    def _eta(self) -> str:
        if self.listed is None or self.pacer is None:
            return ""
        left = max(self.listed - self.fetched, 0)
        per_minute = self.pacer.units_per_minute / UNIT_COST["messages.get"]
        minutes = int(round(left / per_minute)) if per_minute else 0
        return f", ~{minutes // 60}h{minutes % 60:02d}m left at {per_minute:.0f}/min"

    def line(self) -> str:
        if self.listed:
            pct = int(100 * self.fetched / self.listed)
            return f"gmail pull: {self.phase}: fetched {self.fetched}/{self.listed} ({pct}%){self._eta()}"
        return f"gmail pull: {self.phase}: fetched {self.fetched}"

    def emit(self, force: bool = False) -> None:
        if self.out is None:
            return
        now = self.clock()
        if force or self._last is None or now - self._last >= PROGRESS_EVERY:
            self._last = now
            print(self.line(), file=self.out, flush=True)

    def enter(self, phase: str, listed: int | None = None) -> None:
        self.phase = phase
        if listed is not None:
            self.listed = listed
        self.emit(force=True)

    def note(self, text: str) -> None:
        if self.out is not None:
            print(f"gmail pull: {text}", file=self.out, flush=True)


def _http_status(exc) -> int | None:
    resp = getattr(exc, "resp", None)
    status = getattr(resp, "status", None) or getattr(exc, "status_code", None)
    try:
        return int(status) if status is not None else None
    except (TypeError, ValueError):
        return None


class GmailApi:
    """The only code that talks to Google: five read-only calls.

    `service` is what `googleapiclient.discovery.build("gmail", "v1")` returns;
    the test passes a fake with the same call chain, so this wrapper (pagination
    arguments, the 404 mapping) is exercised as well, not mocked away.
    """

    def __init__(self, service, pacer: Pacer | None = None, progress: Progress | None = None, sleep=time.sleep):
        self._users = service.users()
        # No pacer means unpaced: the unit tests' fake service. `paced_api`
        # is what the command builds.
        self.pacer = pacer
        self.progress = progress or Progress()
        self._sleep = sleep

    def _run(self, request, name: str, not_found=None):
        """Execute one call. Every failure leaves as PullError (exit 4), except
        a 404 where the caller says what a missing object means, and a
        rate-limit refusal, which waits for the window and retries."""
        from googleapiclient.errors import HttpError  # lazy: only the image has it

        waited, wait = 0, RATE_WAIT_FIRST
        while True:
            if self.pacer is not None:
                self.pacer.spend(UNIT_COST.get(name, 1))
            try:
                return request.execute(num_retries=RETRIES)
            except HttpError as exc:
                status = _http_status(exc)
                if status == 404 and not_found is not None:
                    return not_found()
                reason, message = _google_error(exc)
                limited = status == 429 or (status == 403 and reason in RATE_LIMIT_REASONS)
                if limited and waited + wait <= RATE_WAIT_GIVE_UP:
                    self.progress.note(
                        f"{name} rate-limited ({reason or status}); waiting {wait}s, then resuming more slowly"
                    )
                    self._sleep(wait)
                    waited += wait
                    wait = min(wait * 2, RATE_WAIT_MAX)
                    if self.pacer is not None:
                        self.pacer.slow_down()
                    continue
                detail = f"{name} answered {status}"
                if reason:
                    detail += f" reason={reason}"
                if message:
                    detail += f' ("{redact(message)}")'
                if limited:
                    detail += f" after waiting {waited // 60} min"
                raise PullError(detail, reason=reason, progress=self.progress.counts()) from exc
            except Exception as exc:  # noqa: BLE001 - transport errors carry no mail
                raise PullError(f"{name}: {type(exc).__name__}", progress=self.progress.counts()) from exc

    def profile(self) -> dict:
        return self._run(self._users.getProfile(userId="me"), "getProfile")

    def list_message_ids(self, page_token: str | None = None) -> dict:
        return self._run(
            self._users.messages().list(
                userId="me", maxResults=LIST_PAGE, pageToken=page_token, includeSpamTrash=False
            ),
            "messages.list",
        )

    def get_message(self, message_id: str) -> dict | None:
        """The full message, or None if it no longer exists."""
        message = self._run(
            self._users.messages().get(userId="me", id=message_id, format="full"),
            "messages.get",
            not_found=lambda: None,
        )
        self.progress.fetched += 1
        self.progress.emit()
        return message

    def get_attachment(self, message_id: str, attachment_id: str) -> dict | None:
        """One attachment part's body, `{"size": n, "data": base64url}`, or
        None if it no longer exists. The only call that fetches content."""
        return self._run(
            self._users.messages().attachments().get(userId="me", messageId=message_id, id=attachment_id),
            "messages.attachments.get",
            not_found=lambda: None,
        )

    def list_history(self, start_history_id: str, page_token: str | None = None) -> dict:
        def expired():
            raise HistoryExpired(start_history_id)

        return self._run(
            self._users.history().list(
                userId="me",
                startHistoryId=start_history_id,
                historyTypes=HISTORY_TYPES,
                maxResults=LIST_PAGE,
                pageToken=page_token,
            ),
            "history.list",
            not_found=expired,
        )


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


def _attachment_parts(payload: dict):
    for part in _walk(payload):
        if part is not payload and _is_attachment(part):
            yield part


def extract_attachments(payload: dict) -> list[dict]:
    """Each attachment part's metadata, for the sealed export. The attachment
    id is not kept: it is a fetch handle, not a fact about the mail."""
    return [
        {
            "name": part.get("filename") or "",
            "mime": part.get("mimeType") or OCTET_STREAM,
            "size": int((part.get("body") or {}).get("size") or 0),
            "part_id": str(part.get("partId") or ""),
        }
        for part in _attachment_parts(payload)
    ]


def normalize_mime(raw) -> str:
    """Gmail's declared type as the explorer normalises a stored one (A2).
    Never sniffed from the bytes."""
    norm = str(raw or "").split(";", 1)[0].strip().lower()
    return norm if _MIME_SHAPE.match(norm) else OCTET_STREAM


def attachment_refs(message: dict) -> list[dict]:
    """What the attachment phase needs of each part, kept out of the export:
    the fetch handle (or inline data), the reported size and the type."""
    out = []
    for part in _attachment_parts(message.get("payload") or {}):
        body = part.get("body") or {}
        out.append(
            {
                "message_id": message["id"],
                "part_id": str(part.get("partId") or ""),
                "attachment_id": body.get("attachmentId"),
                "data": body.get("data"),
                "size": int(body.get("size") or 0),
                "mime": normalize_mime(part.get("mimeType")),
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
    api.progress.enter("listing")
    history_id = str(api.profile()["historyId"])
    ids = [m["id"] for page in _pages(api.list_message_ids) for m in page.get("messages") or []]
    api.progress.enter("fetching", listed=len(ids))
    messages, refs, counts = {}, [], {"listed": len(ids), "gone": 0, "excluded": 0}
    for message_id in ids:
        message = api.get_message(message_id)
        if message is None:
            counts["gone"] += 1
        elif is_excluded(message):
            counts["excluded"] += 1
        else:
            messages[message_id] = normalize_message(message)
            refs.extend(attachment_refs(message))
    return {
        "mode": "full",
        "base_history_id": None,
        "history_id": history_id,
        "messages": [messages[k] for k in sorted(messages)],
        "deleted_ids": [],
        "counts": counts,
        "attachment_refs": refs,
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
    messages, refs = {}, []
    counts = {"history_records": records, "touched": len(touched), "gone": 0, "excluded": 0}
    api.progress.enter("fetching", listed=len(touched - deleted))
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
            refs.extend(attachment_refs(message))
    return {
        "mode": "incremental",
        "base_history_id": start_history_id,
        "history_id": history_id,
        "messages": [messages[k] for k in sorted(messages)],
        "deleted_ids": sorted(deleted),
        "counts": counts,
        "attachment_refs": refs,
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


def build_manifest(run_id: str, export: dict, attachments: dict | None = None) -> dict:
    """The source manifest `scripts/lake_ingest.py` loads (REAL_DATA_INGEST.md).

    One record for the export, and one per distinct attachment blob. A blob's
    path is its hash, so the catalog's `source_path` names no file (A1)."""
    records = [
        {
            "path": EXPORT_NAME,
            "mime": "application/json",
            "kind": "message_export",
            "sensitivity": "high",
        }
    ]
    for digest, mime in sorted((attachments or {}).get("blobs", {}).items()):
        records.append(
            {
                "path": f"{ATTACHMENTS_DIR}/{digest}",
                "mime": mime,
                "kind": ATTACHMENT_KIND,
                # Whatever its type (A7).
                "sensitivity": "high",
            }
        )
    return {
        "dataset_id": DATASET_ID,
        "source": f"{SOURCE} {export['mode']} run {run_id}",
        "records": records,
    }


# --- attachment content (#11557, security c75385) ----------------------------

def _part_key(message_id: str, part_id: str) -> str:
    return f"{message_id}/{part_id}"


def read_seen(staging: Path) -> set[str]:
    """The parts whose links are in the lake, as `message id/part id`: every
    committed run's `links.json`, moved under LINKED_DIR by the wrapper."""
    directory = staging / LINKED_DIR
    if not directory.is_dir():
        return set()
    seen = set()
    for path in sorted(directory.glob("*.json")):
        for link in json.loads(path.read_text("utf-8")).get("links") or []:
            seen.add(_part_key(link["message_id"], link["part_id"]))
    return seen


def plan_attachments(refs: list[dict], seen: set[str]) -> tuple[list[dict], list[dict], int]:
    """(to fetch, over the cap, already fetched by a past run)."""
    to_fetch, over, already = [], [], 0
    for ref in refs:
        if _part_key(ref["message_id"], ref["part_id"]) in seen:
            already += 1
        elif ref["size"] > ATTACHMENT_CAP:
            over.append(ref)
        else:
            to_fetch.append(ref)
    return to_fetch, over, already


def check_space(staging: Path, to_fetch: list[dict], progress: "Progress", disk_free=None) -> None:
    """A5: print the estimate, then refuse if it does not fit. Before any fetch
    and before the run directory exists, so a refusal writes nothing."""
    want = sum(ref["size"] for ref in to_fetch)
    need = want + max(want // 10, SPACE_MARGIN_MIN)
    free = (disk_free or (lambda path: shutil.disk_usage(path).free))(staging)
    progress.note(f"attachments: {len(to_fetch)} part(s) to fetch, {want} bytes reported; {free} bytes free on staging")
    if need > free:
        raise NoSpaceError(
            f"{len(to_fetch)} attachment part(s) to fetch, {want} bytes reported, "
            f"{need} bytes needed with the margin; {free} bytes free on staging"
        )


def fetch_attachments(api: GmailApi, partial: Path, to_fetch: list[dict], over: list[dict]) -> dict:
    """Fetch, check and write each part. Returns the links, the refused parts
    (ids and a reason code) and the distinct blobs with their types."""
    directory = partial / ATTACHMENTS_DIR
    links, refused, blobs, written = [], [], {}, 0

    def refuse(ref: dict, reason: str) -> None:
        refused.append({"message_id": ref["message_id"], "part_id": ref["part_id"], "reason": reason})

    for ref in over:
        refuse(ref, "over_cap")
    for ref in to_fetch:
        data = ref["data"]
        if data is None:
            if not ref["attachment_id"]:
                refuse(ref, "no_content")
                continue
            body = api.get_attachment(ref["message_id"], ref["attachment_id"])
            if body is None:
                refuse(ref, "gone")
                continue
            data = body.get("data") or ""
        # Whole in memory (base64url JSON from Gmail): ATTACHMENT_CAP bounds it.
        try:
            raw = base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))
        except ValueError:
            refuse(ref, "undecodable")
            continue
        if len(raw) > ATTACHMENT_CAP:
            refuse(ref, "over_cap")
            continue
        if len(raw) != ref["size"]:
            refuse(ref, "size_mismatch")
            continue
        digest = hashlib.sha256(raw).hexdigest()
        if digest not in blobs:
            directory.mkdir(mode=0o700, exist_ok=True)
            _write_private(directory / digest, raw)
            blobs[digest] = ref["mime"]
            written += len(raw)
        links.append({"message_id": ref["message_id"], "part_id": ref["part_id"], "sha256": digest})
        del raw
    if blobs:
        _fsync_dir(directory)
    return {"links": links, "refused": refused, "blobs": blobs, "bytes": written}


def _open_partial(staging: Path, run_id: str) -> Path:
    runs = staging / "runs"
    runs.mkdir(mode=0o700, parents=True, exist_ok=True)
    partial = runs / f".{run_id}.partial"
    if partial.exists():
        shutil.rmtree(partial)
    partial.mkdir(mode=0o700)
    return partial


def write_run(
    staging: Path,
    run_id: str,
    export: dict,
    now: datetime,
    partial: Path | None = None,
    attachments: dict | None = None,
) -> Path:
    """Write the export and its manifest (and the attachment links, when the
    run fetched any); the run dir appears only when complete."""
    runs = staging / "runs"
    partial = partial or _open_partial(staging, run_id)
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
    if attachments is not None:
        links = {"links": attachments["links"], "refused": attachments["refused"]}
        _write_private(partial / LINKS_NAME, canonical_json(links))
    manifest = build_manifest(run_id, export, attachments)
    _write_private(partial / MANIFEST_NAME, json.dumps(manifest, indent=1).encode("utf-8"))
    _fsync_dir(partial)
    final = runs / run_id
    os.rename(partial, final)
    _fsync_dir(runs)
    return final


def run_pull(
    api: GmailApi,
    staging: Path,
    *,
    force_full: bool = False,
    now: datetime | None = None,
    attachments: bool = False,
    disk_free=None,
) -> dict:
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
    fetched, att_counts = None, {}
    if attachments:
        to_fetch, over, already = plan_attachments(export["attachment_refs"], read_seen(staging))
        check_space(staging, to_fetch, api.progress, disk_free)
        att_counts = {"att_parts": len(export["attachment_refs"]), "att_already": already}
    run_dir = None
    if changed:
        partial = _open_partial(staging, run_id)
        try:
            if attachments:
                api.progress.note(f"fetching attachments: {len(to_fetch)} part(s)")
                fetched = fetch_attachments(api, partial, to_fetch, over)
            run_dir = write_run(staging, run_id, export, now, partial=partial, attachments=fetched)
        except BaseException:
            # Clear attachment bytes are not left in a partial run directory.
            shutil.rmtree(partial, ignore_errors=True)
            raise
    if fetched is not None:
        refused = fetched["refused"]
        att_counts.update(
            att_fetched=len(fetched["links"]),
            att_blobs=len(fetched["blobs"]),
            att_bytes=fetched["bytes"],
            att_refused=len(refused),
            # By ids and reason code only (A4, A8).
            att_refused_parts=",".join(f"{r['message_id']}/{r['part_id']}:{r['reason']}" for r in refused) or None,
        )
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
        **att_counts,
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


def paced_api(service, units_per_minute: int | None = None, clock=time.monotonic, sleep=time.sleep, out=None) -> GmailApi:
    """The API the command uses: every call paced under the per-user quota,
    progress on `out` (stderr by default)."""
    pacer = Pacer(units_per_minute or units_per_minute_from_env(), clock=clock, sleep=sleep)
    progress = Progress(clock=clock, out=sys.stderr if out is None else out, pacer=pacer)
    return GmailApi(service, pacer=pacer, progress=progress, sleep=sleep)


def _build_api(creds) -> GmailApi:
    from googleapiclient.discovery import build  # lazy

    return paced_api(build("gmail", "v1", credentials=creds, cache_discovery=False))


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
            summary = run_pull(_build_api(creds), staging, force_full=args.full, attachments=args.attachments)
    except BlockingIOError:
        print("another gmail pull holds the staging lock; try again when it ends", file=sys.stderr)
        return EXIT_LOCKED
    except PullError as exc:
        print(f"pull failed (transport or API): {exc}; the stored history id is unchanged", file=sys.stderr)
        return gmail_auth.EXIT_TRANSPORT
    except NoSpaceError as exc:
        print(f"refused: {exc}; nothing written, the stored history id is unchanged", file=sys.stderr)
        return EXIT_NO_SPACE
    print(render_summary(summary))
    return gmail_auth.EXIT_OK


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--full", action="store_true", help="ignore the stored history id and pull everything")
    parser.add_argument(
        "--attachments",
        action="store_true",
        help="also fetch attachment content not fetched before (system_3 #11557); prints the estimate first",
    )
    args = parser.parse_args(argv)
    return cmd_pull(args)


if __name__ == "__main__":
    sys.exit(main())
