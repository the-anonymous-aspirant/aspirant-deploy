#!/usr/bin/env python3
"""Gmail OAuth bootstrap: loopback consent and an envelope-encrypted refresh token.

system_3 #8806-A1 (epic #8806, operator request c54425 on #4383). This is the
credential lifecycle for the on-demand Gmail -> data-lake pull. It fetches no
mail; `gmail_pull.py` (#8806-B1) imports `load_credentials` from here.

What it does, and what never happens:

* `consent`  runs the installed-app (Desktop) OAuth flow for exactly one scope,
  `gmail.readonly`. The authorisation URL is printed; the operator opens it on
  their own machine and Google redirects to `http://localhost:<port>/`, which
  reaches this process through the operator's SSH tunnel
  (`ssh -L <port>:127.0.0.1:<port> aspirant@<cell>`). No public callback URL
  exists and nothing on the website changes.
* The authorised-user record (refresh token, client id and secret, token URI,
  scopes) is written only as a lake envelope: `token.aobj` (AES-256-GCM object
  under a fresh DEK) plus `token.wdek` (the DEK wrapped under the lake KEK,
  `scripts/kek/dek_envelope.py`). The KEK is loaded by
  `scripts/kek/kek_loader.require_kek`, one-shot env or hidden prompt, never on
  disk; without a KEK this program refuses, exactly like the ingest runner.
* `status` reads the non-secret sidecar `token.meta.json`; `status --check`
  decrypts in memory, refreshes the access token once and says `ok` or
  `re-consent needed` (exit 3). It never prints a token.
* `--self-test` runs the whole thing with an ephemeral synthetic KEK, a fake
  client config and a fake refresh transport: no network, no real key material.

Exit codes: 0 ok; 2 KEK or envelope failure; 3 re-consent needed; 4 transport
error; 5 configuration refused (scope, client type); 6 no token stored yet.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
KEK_DIR = Path(os.environ.get("GMAIL_KEK_DIR", HERE.parent / "kek"))
sys.path.insert(0, str(KEK_DIR))

import dek_envelope  # noqa: E402
import envelope_store  # noqa: E402
import kek_loader  # noqa: E402

SCOPE = "https://www.googleapis.com/auth/gmail.readonly"
SECRETS_DIR = Path(os.environ.get("GMAIL_SECRETS_DIR", "/secrets/gmail"))
CLIENT_JSON = Path(os.environ.get("GMAIL_CLIENT_JSON", "/secrets/gmail-oauth-client.json"))
DEFAULT_PORT = 8765

EXIT_OK, EXIT_KEK, EXIT_RECONSENT, EXIT_TRANSPORT, EXIT_CONFIG, EXIT_NO_TOKEN = 0, 2, 3, 4, 5, 6
RECONSENT_LINE = "re-consent needed: run `scripts/gmail/gmail.sh consent` (through the SSH tunnel) and try again"

# The fields of the authorised-user record that are secrets. They are the
# reason the record is stored as an envelope and never printed.
SECRET_FIELDS = ("refresh_token", "client_secret", "token")


class ConfigError(Exception):
    """A refusal before any credential is touched (scope, client type)."""


def token_paths(secrets_dir: Path | None = None) -> dict[str, Path]:
    d = secrets_dir or SECRETS_DIR
    return {"aobj": d / "token.aobj", "wdek": d / "token.wdek", "meta": d / "token.meta.json"}


# --- scope and client guards ------------------------------------------------

def check_client_config(config: dict) -> dict:
    """A Desktop ("installed") client only; the loopback redirect needs it."""
    installed = config.get("installed")
    if not isinstance(installed, dict):
        raise ConfigError(
            "the OAuth client JSON is not a Desktop-app client (no 'installed' key); "
            "create the client as 'Desktop app' in Google Cloud and download it again"
        )
    for key in ("client_id", "client_secret", "token_uri"):
        if not installed.get(key):
            raise ConfigError(f"the OAuth client JSON lacks '{key}'")
    return installed


def check_scopes(scopes) -> None:
    """Exactly one scope, read-only. Anything else is refused, not trimmed."""
    got = set(scopes or [])
    if got != {SCOPE}:
        raise ConfigError(f"scopes must be exactly {{{SCOPE}}}, got {sorted(got)}")


# --- envelope ----------------------------------------------------------------

def seal_token(info: dict, kek: bytes, kek_version: int = 1) -> tuple[bytes, str]:
    """Authorised-user record -> (aobj bytes, wrapped DEK base64)."""
    check_scopes(info.get("scopes"))
    record = {k: v for k, v in info.items() if k not in ("token", "expiry")}
    plaintext = json.dumps(record, sort_keys=True).encode("utf-8")
    return envelope_store.encrypt_for_storage(plaintext, kek, kek_version)


def open_token(aobj: bytes, wdek_b64: str, kek: bytes) -> dict:
    """(aobj, wrapped DEK) -> authorised-user record, in memory only."""
    plaintext = envelope_store.decrypt_from_storage(aobj, wdek_b64, lambda _version: kek)
    info = json.loads(plaintext.decode("utf-8"))
    check_scopes(info.get("scopes"))
    return info


def write_token(info: dict, kek: bytes, kek_version: int, secrets_dir: Path, note: str = "") -> dict:
    paths = token_paths(secrets_dir)
    secrets_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(secrets_dir, 0o700)
    aobj, wdek_b64 = seal_token(info, kek, kek_version)
    for path, data in ((paths["aobj"], aobj), (paths["wdek"], wdek_b64.encode("ascii"))):
        _write_private(path, data)
    meta = {
        "obtained_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "scopes": sorted(info.get("scopes") or []),
        "client_id": info.get("client_id", ""),
        "kek_version": kek_version,
        "kek_fingerprint": kek_loader.fingerprint(kek),
        "note": note,
    }
    _write_private(paths["meta"], json.dumps(meta, indent=1, sort_keys=True).encode("utf-8"))
    return meta


def _write_private(path: Path, data: bytes) -> None:
    """Write a 0600 file atomically: temp file, fchmod, fsync, os.replace.

    `O_TRUNC` on an existing file would keep its old mode, and a crash between
    the `.aobj` and `.wdek` writes would leave a pair that reads as a wrong key
    (review c54457); the temp-and-replace shape closes both.
    """
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


def read_meta(secrets_dir: Path | None = None) -> dict | None:
    paths = token_paths(secrets_dir)
    if not (paths["aobj"].exists() and paths["wdek"].exists()):
        return None
    try:
        return json.loads(paths["meta"].read_text())
    except (OSError, ValueError):
        return {"obtained_at": "unknown", "scopes": [], "note": "meta sidecar missing or unreadable"}


def load_credentials(kek: bytes, secrets_dir: Path | None = None):
    """The function the pull imports: a google Credentials object, or raise.

    Raises FileNotFoundError when no token is stored, dek_envelope.EnvelopeError
    when the KEK does not open it, ConfigError when the scopes are wrong.
    """
    paths = token_paths(secrets_dir)
    if not (paths["aobj"].exists() and paths["wdek"].exists()):
        raise FileNotFoundError("no Gmail token stored; run `gmail.sh consent` first")
    info = open_token(paths["aobj"].read_bytes(), paths["wdek"].read_text().strip(), kek)
    from google.oauth2.credentials import Credentials  # lazy: the self-test has no google libs

    return Credentials.from_authorized_user_info(info, scopes=[SCOPE])


# --- consent flow ------------------------------------------------------------

def build_flow(client_json_path: str):
    """The loopback consent flow, with PKCE made mandatory.

    google-auth-oauthlib's `from_client_secrets_file` passes
    `autogenerate_code_verifier=None` through to the constructor, which drops
    the PKCE challenge (security review #8807 c54457; RFC 8252 §8.1 requires it
    for native-app loopback flows). It is set explicitly here and checked
    afterwards, so a library change cannot silently remove it again.
    """
    from google_auth_oauthlib.flow import InstalledAppFlow  # lazy

    flow = InstalledAppFlow.from_client_secrets_file(
        client_json_path, scopes=[SCOPE], autogenerate_code_verifier=True
    )
    if not getattr(flow, "autogenerate_code_verifier", False):
        raise ConfigError("the OAuth flow would run without a PKCE code verifier; refusing")
    return flow


# --- refresh check -----------------------------------------------------------

def classify_refresh(refresh) -> tuple[int, str]:
    """Run one refresh attempt and map its outcome to (exit code, line).

    `refresh` is a zero-argument callable that performs the refresh and raises
    on failure; the CLI passes the real google-auth refresh, the self-test a
    fake. `invalid_grant` is Google's answer for a revoked or expired refresh
    token (the 7-day Testing expiry included), which is the loud signal the
    epic asks for.
    """
    try:
        refresh()
    except Exception as exc:  # noqa: BLE001 - the classification is the point
        text = str(exc)
        if "invalid_grant" in text or "Token has been expired or revoked" in text:
            return EXIT_RECONSENT, RECONSENT_LINE
        return EXIT_TRANSPORT, f"refresh failed (transport or server): {type(exc).__name__}"
    return EXIT_OK, "ok: the stored refresh token still mints access tokens"


def render_status(meta: dict | None) -> str:
    if meta is None:
        return "no token stored (run `scripts/gmail/gmail.sh consent`)"
    lines = [
        "token: stored (envelope-encrypted, lake KEK)",
        f"obtained_at: {meta.get('obtained_at', 'unknown')}",
        f"scopes: {' '.join(meta.get('scopes') or []) or 'unknown'}",
        f"kek_version: {meta.get('kek_version', 'unknown')}",
        f"kek_fingerprint: {meta.get('kek_fingerprint', '') or 'unknown'}",
    ]
    if meta.get("note"):
        lines.append(f"note: {meta['note']}")
    lines.append(
        "consent screen in Testing: Google expires this token 7 days after obtained_at; "
        "`status --check` tells you whether it still works"
    )
    return "\n".join(lines)


# --- commands ----------------------------------------------------------------

def _kek() -> tuple[bytes, int]:
    version = int(os.environ.get("LAKE_KEK_VERSION", "1"))
    return kek_loader.require_kek(kek_version=version), version


def cmd_consent(args) -> int:
    try:
        config = json.loads(CLIENT_JSON.read_text())
    except OSError as exc:
        print(f"cannot read the OAuth client JSON at {CLIENT_JSON}: {exc}", file=sys.stderr)
        return EXIT_CONFIG
    try:
        check_client_config(config)
    except ConfigError as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return EXIT_CONFIG
    try:
        kek, version = _kek()
    except kek_loader.KekLoadError as exc:
        print(f"refused: no usable KEK ({exc}); the token is only ever stored encrypted", file=sys.stderr)
        return EXIT_KEK
    try:
        flow = build_flow(str(CLIENT_JSON))
    except ConfigError as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return EXIT_CONFIG
    message = (
        "\nOpen this URL in a browser on YOUR machine. Google will redirect to "
        f"http://localhost:{args.port}/ which must reach this process through your SSH "
        f"tunnel (ssh -L {args.port}:127.0.0.1:{args.port} ...):\n\n{{url}}\n"
    )
    creds = flow.run_local_server(
        host="localhost",
        bind_addr="127.0.0.1",
        port=args.port,
        open_browser=False,
        authorization_prompt_message=message,
        access_type="offline",
        prompt="consent",
    )
    info = json.loads(creds.to_json())
    granted = getattr(creds, "granted_scopes", None)
    if granted is not None and set(granted) != {SCOPE}:
        print(f"refused: Google granted {sorted(granted)}, not exactly {{{SCOPE}}}; nothing stored", file=sys.stderr)
        return EXIT_CONFIG
    if not info.get("refresh_token"):
        print("Google returned no refresh token; nothing stored. Re-run consent (prompt=consent is set).", file=sys.stderr)
        return EXIT_TRANSPORT
    try:
        meta = write_token(info, kek, version, SECRETS_DIR, note=args.note or "")
    except ConfigError as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return EXIT_CONFIG
    print("stored the refresh token as a lake envelope (never in clear).")
    print(render_status(meta))
    return EXIT_OK


def cmd_status(args) -> int:
    meta = read_meta(SECRETS_DIR)
    print(render_status(meta))
    if meta is None:
        return EXIT_NO_TOKEN
    if not args.check:
        return EXIT_OK
    try:
        kek, _version = _kek()
    except kek_loader.KekLoadError as exc:
        print(f"check skipped: no usable KEK ({exc})", file=sys.stderr)
        return EXIT_KEK
    try:
        creds = load_credentials(kek, SECRETS_DIR)
    except dek_envelope.EnvelopeError:
        print("KEK does not open the stored token (wrong key or tampered file)", file=sys.stderr)
        return EXIT_KEK
    except ConfigError as exc:
        print(f"refused: {exc}", file=sys.stderr)
        return EXIT_CONFIG
    from google.auth.transport.requests import Request  # lazy

    code, line = classify_refresh(lambda: creds.refresh(Request()))
    print(line)
    return code


# --- self-test (ephemeral KEK, no network, no real material) -----------------

def _self_test() -> int:
    import tempfile

    passed = failed = 0

    def check(name: str, ok: bool, detail: str = "") -> None:
        nonlocal passed, failed
        if ok:
            passed += 1
            print(f"[PASS] {name}")
        else:
            failed += 1
            print(f"[FAIL] {name}: {detail}")

    kek = os.urandom(32)
    wrong = os.urandom(32)
    info = {
        "refresh_token": "1//SELFTEST-REFRESH-TOKEN-NOT-REAL",
        "client_id": "123-selftest.apps.googleusercontent.com",
        "client_secret": "GOCSPX-SELFTEST-SECRET-NOT-REAL",
        "token_uri": "https://oauth2.googleapis.com/token",
        "token": "ya29.SELFTEST-ACCESS-TOKEN",
        "scopes": [SCOPE],
        "expiry": "2026-01-01T00:00:00Z",
    }
    aobj, wdek = seal_token(info, kek, 1)
    back = open_token(aobj, wdek, kek)
    check("round-trip keeps the refresh token and client fields", back["refresh_token"] == info["refresh_token"] and back["client_secret"] == info["client_secret"])
    check("the access token and expiry are not persisted", "token" not in back and "expiry" not in back)
    leaked = [f for f in ("refresh_token", "client_secret") if info[f].encode() in aobj]
    check("the stored object contains no secret in clear", not leaked, str(leaked))
    check("the stored object carries the AOBJ header", aobj[:4] == b"AOBJ", repr(aobj[:4]))
    try:
        open_token(aobj, wdek, wrong)
        check("a wrong KEK is refused", False, "no error")
    except dek_envelope.EnvelopeError:
        check("a wrong KEK is refused", True)
    try:
        seal_token({**info, "scopes": [SCOPE, "https://www.googleapis.com/auth/gmail.modify"]}, kek, 1)
        check("a wider scope set is refused", False, "no error")
    except ConfigError:
        check("a wider scope set is refused", True)
    try:
        check_client_config({"web": {"client_id": "x"}})
        check("a Web client is refused", False, "no error")
    except ConfigError:
        check("a Web client is refused", True)

    def raise_invalid_grant():
        raise RuntimeError("('invalid_grant: Token has been expired or revoked.', ...)")

    def raise_transport():
        raise ConnectionError("name resolution failed")

    code, line = classify_refresh(raise_invalid_grant)
    check("invalid_grant maps to exit 3 with the re-consent line", code == EXIT_RECONSENT and line == RECONSENT_LINE, f"{code} {line}")
    code, line = classify_refresh(raise_transport)
    check("a transport error maps to exit 4", code == EXIT_TRANSPORT, f"{code} {line}")
    code, line = classify_refresh(lambda: None)
    check("a successful refresh maps to exit 0", code == EXIT_OK and line.startswith("ok"), f"{code} {line}")

    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "gmail"
        meta = write_token(info, kek, 1, d, note="self-test")
        modes = {p.name: oct(p.stat().st_mode & 0o777) for p in d.iterdir()}
        check("token files are 0600", all(m == "0o600" for m in modes.values()), str(modes))
        status = render_status(read_meta(d))
        check("status names obtained_at, scopes and kek_version", all(k in status for k in ("obtained_at", SCOPE, "kek_version")), status)
        check("status prints no secret", not any(info[f] in status for f in SECRET_FIELDS), status)
        check("status mentions the 7-day Testing expiry", "7 days" in status)
        try:
            open_token(d.joinpath("token.aobj").read_bytes(), d.joinpath("token.wdek").read_text(), kek)
            check("the written files open with the same KEK", True)
        except Exception as exc:  # noqa: BLE001
            check("the written files open with the same KEK", False, repr(exc))
        check("meta sidecar carries no secret", not any(info[f] in json.dumps(meta) for f in SECRET_FIELDS))
    check("no-token status reads as such", "no token stored" in render_status(None))
    with tempfile.TemporaryDirectory() as tmp:
        d = Path(tmp) / "gmail"; d.mkdir()
        stale = d / "token.aobj"; stale.write_bytes(b"old"); os.chmod(stale, 0o644)
        write_token(info, kek, 1, d)
        check("an existing 0644 token file is rewritten as 0600", oct(stale.stat().st_mode & 0o777) == "0o600")
        check("no temp file is left behind", not list(d.glob("*.tmp")))
    try:
        import google_auth_oauthlib  # noqa: F401
    except ImportError:
        print("[SKIP] PKCE check: google-auth-oauthlib not installed in this interpreter")
    else:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / "client.json"
            cfg.write_text(json.dumps({"installed": {"client_id": "123-selftest.apps.googleusercontent.com", "client_secret": "GOCSPX-SELFTEST-SECRET-NOT-REAL", "token_uri": "https://oauth2.googleapis.com/token", "auth_uri": "https://accounts.google.com/o/oauth2/auth", "redirect_uris": ["http://localhost"]}}))
            flow = build_flow(str(cfg))
            check("the flow autogenerates a PKCE code verifier", flow.autogenerate_code_verifier is True)
            flow.redirect_uri = "http://localhost:8765/"
            url, _state = flow.authorization_url(access_type="offline", prompt="consent")
            check("the authorisation URL carries code_challenge and S256", "code_challenge=" in url and "code_challenge_method=S256" in url, url[:160])
    print(f"self-test: {passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--self-test", action="store_true", help="run the offline self-test and exit")
    sub = parser.add_subparsers(dest="command")
    p_consent = sub.add_parser("consent", help="run the loopback consent flow and store the token encrypted")
    p_consent.add_argument("--port", type=int, default=DEFAULT_PORT)
    p_consent.add_argument("--note", default="", help="free text kept in the non-secret sidecar (e.g. 'consent screen: Testing')")
    p_status = sub.add_parser("status", help="report the stored token without revealing it")
    p_status.add_argument("--check", action="store_true", help="decrypt in memory and refresh once (needs the KEK)")
    args = parser.parse_args(argv)
    if args.self_test:
        return _self_test()
    if args.command == "consent":
        return cmd_consent(args)
    if args.command == "status":
        return cmd_status(args)
    parser.print_help()
    return EXIT_CONFIG


if __name__ == "__main__":
    sys.exit(main())
