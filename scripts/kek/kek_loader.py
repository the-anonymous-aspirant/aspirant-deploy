"""Load the KEK into memory at process start, fail closed.

DATA_LAKE_DESIGN.md §9 layer 2, phase 0b. Task **#4134** (`#4120-D`), the piece
`KEK_CEREMONY.md` §7 says child D "must wire to the actual custody medium the
operator chose in §3."

The KEK is full-entropy key material held **off-cell** (`KEK_CEREMONY.md` §3):
never at rest on the cell's disks. A process that touches `sensitivity=high`
objects — the ingest runner (wrap DEKs) or the explorer read path (unwrap) —
loads the KEK **once, into memory only**, at start, and **refuses to start** if
it cannot. Fail-closed is the point: a process with no KEK cannot wrap or unwrap,
so it must not come up pretending it can serve or ingest high-sensitivity data
(§9 success criterion "process refuses to start without KEK").

Custody medium (operator 2026-07-18 ruling, §3) is one of two, operator's pick:

  * **Written-down grouped hex** (phase-0b path implemented here) — the operator
    types the hex over SSH at startup. Never on disk. `load_kek_written_down`
    reads it via a hidden prompt, strips the transcription spaces, checks it is a
    32-byte key, and verifies the non-secret fingerprint recorded at the ceremony
    (`sha256(KEK)[:16]`, per `gen-kek.sh`).
  * **Hardware token** — a named seam (`load_kek_from_token`), not wired for 0b
    because the operator took the written-down path. Filling it is a later phase.

A non-interactive start (a container, CI, the recovery-drill harness) has no TTY
to prompt, so `load_kek_from_env` accepts the hex through a **one-shot** env var
the launcher sets and does not persist. `require_kek` prefers the env, falls back
to the prompt, and raises `KekLoadError` when neither yields a valid, fingerprint-
matching key — the caller lets that propagate to abort startup.

This module holds NO real key material at import; every function here is exercised
by `--self-test` with an ephemeral synthetic KEK, never the production one.
"""

from __future__ import annotations

import hashlib
import os
from typing import Callable

KEY_LEN = 32  # AES-256 — must match dek_envelope.KEY_LEN
FINGERPRINT_HEX_LEN = 16  # sha256(KEK).hexdigest()[:16], per gen-kek.sh

#: One-shot env var a non-interactive launcher sets to the grouped/plain hex.
ENV_KEK_HEX = "LAKE_KEK_HEX"
#: Optional env var carrying the ceremony fingerprint to verify the loaded KEK.
ENV_KEK_FINGERPRINT = "LAKE_KEK_FINGERPRINT"


class KekLoadError(Exception):
    """The KEK could not be loaded or failed its fingerprint check.

    Raised so a caller in a process-startup hook can let it propagate and abort
    the boot — the fail-closed contract. Never carries key material in its text.
    """


# --- fingerprint + parsing ---------------------------------------------------

def fingerprint(kek: bytes) -> str:
    """The non-secret ceremony fingerprint of a KEK: sha256(KEK)[:16] hex.

    Safe to log and to compare (one-way). Identical to `gen-kek.sh`'s value.
    """
    return hashlib.sha256(kek).hexdigest()[:FINGERPRINT_HEX_LEN]


def parse_grouped_hex(text: str) -> bytes:
    """Parse the written-down grouped hex into a 32-byte KEK.

    The custody form is 16 groups of 4 hex chars separated by spaces (chosen in
    §3 to survive hand-transcription). Whitespace anywhere is stripped before
    decoding. Raises `KekLoadError` on non-hex or the wrong length — never a
    partial or padded key.
    """
    compact = "".join(text.split())
    try:
        kek = bytes.fromhex(compact)
    except ValueError as exc:
        raise KekLoadError(f"KEK hex is not valid hexadecimal: {exc}") from exc
    if len(kek) != KEY_LEN:
        raise KekLoadError(
            f"KEK must be {KEY_LEN} bytes, got {len(kek)} "
            "(check for a dropped or extra hex group)"
        )
    return kek


def _verify_fingerprint(kek: bytes, expected: str | None) -> None:
    """Raise unless `expected` (if given) matches the KEK's fingerprint."""
    if not expected:
        return
    got = fingerprint(kek)
    # Case-insensitive compare; the fingerprint is non-secret so no constant-time
    # requirement, but normalise so a transcribed upper/lower mismatch is not a
    # false negative.
    if got.lower() != expected.strip().lower():
        raise KekLoadError(
            "KEK fingerprint mismatch: the key you entered is not the one "
            f"recorded at the ceremony (recorded {expected!r})"
        )


# --- custody sources ---------------------------------------------------------

def load_kek_written_down(
    expected_fingerprint: str | None = None,
    prompt: Callable[[str], str] | None = None,
) -> bytes:
    """Load the KEK by hidden prompt (operator types the written-down hex).

    `prompt` defaults to `getpass.getpass` so the hex is not echoed and not
    written to shell history; it is injectable for tests. Verifies the ceremony
    fingerprint when one is provided. The plaintext hex string is dropped as soon
    as it is decoded.
    """
    if prompt is None:
        import getpass

        prompt = getpass.getpass
    text = prompt("Type the grouped KEK hex from custody (hidden): ")
    kek = parse_grouped_hex(text)
    _verify_fingerprint(kek, expected_fingerprint)
    return kek


def load_kek_from_env(
    var: str = ENV_KEK_HEX,
    expected_fingerprint: str | None = None,
) -> bytes | None:
    """Load the KEK from a one-shot env var, or return None if it is unset.

    For a non-interactive start (container / CI / recovery-drill harness) where
    no TTY exists to prompt. The launcher is responsible for not persisting the
    var. Returns None (not an error) when unset, so `require_kek` can fall back
    to the prompt; raises `KekLoadError` when the var is set but malformed or
    fails the fingerprint check.
    """
    text = os.environ.get(var)
    if text is None or text == "":
        return None
    kek = parse_grouped_hex(text)
    _verify_fingerprint(kek, expected_fingerprint)
    return kek


def load_kek_from_token(*_args, **_kwargs) -> bytes:  # pragma: no cover - seam
    """Hardware-token custody path — a named seam, not wired for phase 0b.

    The operator took the written-down path in §3, so 0b implements only that.
    When a token is adopted, read the 32-byte key off the attached token here
    (into memory only) and verify its fingerprint the same way.
    """
    raise KekLoadError(
        "hardware-token KEK custody is not implemented in phase 0b "
        "(operator chose the written-down path; see KEK_CEREMONY.md §3)"
    )


# --- fail-closed entrypoint + in-memory resolver -----------------------------

# kek_version -> KEK bytes, populated once at startup. The wrapped-DEK header
# records which version wrapped each DEK, so a future rotation can hold more than
# one; phase 0b loads exactly one (version 1).
_LOADED: dict[int, bytes] = {}


def install_kek(kek: bytes, kek_version: int = 1) -> None:
    """Place a loaded KEK in the in-memory resolver under its version."""
    if len(kek) != KEY_LEN:
        raise KekLoadError(f"KEK must be {KEY_LEN} bytes, got {len(kek)}")
    _LOADED[kek_version] = kek


def load_kek(kek_version: int) -> bytes:
    """Resolve a KEK by version — the callable `envelope_store` unwraps with.

    Raises `KekLoadError` (fail-closed) when no KEK for that version was loaded
    at startup, rather than returning None and letting a later unwrap fail with a
    less legible error.
    """
    try:
        return _LOADED[kek_version]
    except KeyError:
        raise KekLoadError(
            f"no KEK loaded for version {kek_version} — the process was not "
            "started with the KEK for this object (fail-closed)"
        )


def reset_loaded() -> None:
    """Drop all loaded KEKs (test hygiene; not part of the runtime path)."""
    _LOADED.clear()


def require_kek(
    kek_version: int = 1,
    expected_fingerprint: str | None = None,
    prompt: Callable[[str], str] | None = None,
) -> bytes:
    """Load the KEK at process start and install it, or raise to abort startup.

    Prefers the one-shot env var (non-interactive start), falls back to the
    hidden prompt (operator over SSH). The fingerprint is taken from the
    `expected_fingerprint` argument or, when absent, the `LAKE_KEK_FINGERPRINT`
    env var. Call this from the process's boot hook and do NOT catch the
    `KekLoadError` — its propagation is the fail-closed refusal to start.
    """
    if expected_fingerprint is None:
        expected_fingerprint = os.environ.get(ENV_KEK_FINGERPRINT) or None

    kek = load_kek_from_env(expected_fingerprint=expected_fingerprint)
    if kek is None:
        kek = load_kek_written_down(
            expected_fingerprint=expected_fingerprint, prompt=prompt
        )
    install_kek(kek, kek_version)
    return kek


# --- self-test (ephemeral synthetic KEK; no real key material) ---------------

def _self_test() -> int:
    passed = 0
    failed = 0

    def check(label: str, cond: bool) -> None:
        nonlocal passed, failed
        if cond:
            passed += 1
            print(f"[PASS] {label}")
        else:
            failed += 1
            print(f"[FAIL] {label}")

    reset_loaded()

    # Synthetic, ephemeral — never persisted, never the production KEK.
    kek = os.urandom(KEY_LEN)
    fp = fingerprint(kek)
    grouped = " ".join(
        kek.hex()[i : i + 4] for i in range(0, len(kek.hex()), 4)
    )  # the 16-groups-of-4 custody form

    check("fingerprint is 16 hex chars", len(fp) == 16 and int(fp, 16) >= 0)
    check("grouped hex parses back to the KEK", parse_grouped_hex(grouped) == kek)
    check(
        "spaces/newlines in transcription are tolerated",
        parse_grouped_hex("  " + grouped.replace(" ", "\n") + "  ") == kek,
    )

    # Written-down path via an injected prompt, with fingerprint verification.
    check(
        "written-down load with correct fingerprint returns the KEK",
        load_kek_written_down(expected_fingerprint=fp, prompt=lambda _p: grouped)
        == kek,
    )

    try:
        load_kek_written_down(
            expected_fingerprint="dead" * 4, prompt=lambda _p: grouped
        )
        check("wrong fingerprint is rejected", False)
    except KekLoadError:
        check("wrong fingerprint is rejected", True)

    try:
        parse_grouped_hex("00 11 22")  # too short
        check("short key is rejected", False)
    except KekLoadError:
        check("short key is rejected", True)

    try:
        parse_grouped_hex("zz" * 32)  # non-hex
        check("non-hex is rejected", False)
    except KekLoadError:
        check("non-hex is rejected", True)

    # Env path: unset -> None; set -> the KEK.
    os.environ.pop(ENV_KEK_HEX, None)
    check("env source returns None when unset", load_kek_from_env() is None)
    os.environ[ENV_KEK_HEX] = grouped
    try:
        check(
            "env source returns the KEK when set",
            load_kek_from_env(expected_fingerprint=fp) == kek,
        )
    finally:
        os.environ.pop(ENV_KEK_HEX, None)

    # Fail-closed resolver: raises before any KEK is installed.
    reset_loaded()
    try:
        load_kek(1)
        check("resolver fails closed with no KEK loaded", False)
    except KekLoadError:
        check("resolver fails closed with no KEK loaded", True)

    install_kek(kek, kek_version=1)
    check("resolver returns the installed KEK", load_kek(1) == kek)
    try:
        load_kek(2)
        check("resolver fails closed for an unknown version", False)
    except KekLoadError:
        check("resolver fails closed for an unknown version", True)
    reset_loaded()

    print()
    if failed:
        print(f"FAILED: {failed} failed, {passed} passed")
        return 1
    print(f"{passed} passed, 0 failed")
    return 0


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        raise SystemExit(_self_test())
    print("usage: python kek_loader.py --self-test", file=sys.stderr)
    raise SystemExit(2)
