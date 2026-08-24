"""Storage-facing envelope helpers over `dek_envelope`.

DATA_LAKE_DESIGN.md §9 layer 2, phase 0b. Task **#4134** (`#4120-D`).

Turning a plaintext object into the two things storage actually holds — the
encrypted object bytes that go to Garage, and the base64 wrapped-DEK that rides
in the asset-inventory row — is a fixed three-step sequence (generate DEK,
encrypt object, wrap DEK). Both sides of the lake do it: the ingest runner on
`PUT` (encrypt) and the explorer read path on serve (decrypt). This module is
the **one** place that sequence and the inventory-row base64 live, so the two
paths cannot drift.

All cryptography is in `dek_envelope` (task #4133); this module only sequences
those functions and does the base64 the text inventory column needs. It holds no
key material and no state.

    from envelope_store import encrypt_for_storage, decrypt_from_storage

    aobj_bytes, wrapped_dek_b64 = encrypt_for_storage(plaintext, kek)   # ingest
    # ... s3.put_object(Body=aobj_bytes); inventory row .wrapped_dek = wrapped_dek_b64

    plaintext = decrypt_from_storage(aobj_bytes, wrapped_dek_b64, load_kek)  # read
"""

from __future__ import annotations

import base64
from typing import Callable

from dek_envelope import (
    decrypt_object,
    encrypt_object,
    generate_dek,
    unwrap_dek,
    wrap_dek,
    wrapped_dek_kek_version,
)


def encrypt_for_storage(
    plaintext: bytes, kek: bytes, kek_version: int = 1
) -> tuple[bytes, str]:
    """Encrypt one object for storage under a fresh per-object DEK.

    Returns ``(aobj_bytes, wrapped_dek_b64)``:

      * ``aobj_bytes`` — the AES-256-GCM-encrypted object (with its ``AOBJ``
        header); this is the ``Body`` of the Garage ``PUT``. Reading it raw shows
        the header + ciphertext, never plaintext (the §9 success criterion).
      * ``wrapped_dek_b64`` — the wrapped DEK, base64-encoded for the text
        ``wrapped_dek`` column of the asset-inventory row.

    The plaintext DEK exists only for the duration of this call.
    """
    dek = generate_dek()
    aobj_bytes = encrypt_object(plaintext, dek)
    wrapped = wrap_dek(dek, kek, kek_version)
    return aobj_bytes, base64.b64encode(wrapped).decode("ascii")


def storage_body_and_wrapped_dek(
    payload: bytes, sensitivity: str, kek: bytes, kek_version: int = 1
) -> tuple[bytes, str | None]:
    """The ingest-side sensitivity gate: what to PUT and what to inventory.

    Returns ``(stored_body, wrapped_dek_b64)``:

      * ``sensitivity == "high"`` -> ``(ciphertext, wrapped_dek_b64)`` — the blob
        is envelope-encrypted before it reaches Garage.
      * anything else -> ``(payload, None)`` — stored as-is, no wrapped DEK.

    Centralising the gate here (rather than in the ingest script) keeps the rule
    "only ``high`` is encrypted" testable without standing up Garage, and gives
    the read path one predicate for "is this row encrypted?" — ``wrapped_dek is
    not None``.
    """
    if sensitivity == "high":
        return encrypt_for_storage(payload, kek, kek_version)
    return payload, None


def decrypt_from_storage(
    aobj_bytes: bytes,
    wrapped_dek_b64: str,
    load_kek: Callable[[int], bytes],
) -> bytes:
    """Recover the plaintext of a stored object.

    ``load_kek`` is a ``kek_version -> KEK`` resolver (e.g.
    ``kek_loader.load_kek``); the version is read from the wrapped-DEK header
    *without* any key material, so the caller can fetch the right KEK from
    custody before it holds a key. A wrong KEK, a wrong ``kek_version``, or a
    tampered blob raises ``dek_envelope.EnvelopeError`` from the GCM tag check —
    it never returns garbage.
    """
    wrapped = base64.b64decode(wrapped_dek_b64)
    kek = load_kek(wrapped_dek_kek_version(wrapped))
    dek = unwrap_dek(wrapped, kek)
    return decrypt_object(aobj_bytes, dek)


# --- self-test (ephemeral synthetic KEK; no real key material) ---------------

def _self_test() -> int:
    import os

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

    # Synthetic, ephemeral KEK — never persisted, never the production KEK.
    kek = os.urandom(32)
    plaintext = b"SYNTHETIC -- envelope_store self-test object " + os.urandom(2048)

    aobj, wrapped_b64 = encrypt_for_storage(plaintext, kek, kek_version=1)

    check("stored object bytes are not plaintext", plaintext not in aobj)
    check("stored object carries the AOBJ header", aobj[:4] == b"AOBJ")
    check(
        "wrapped-DEK is base64 ascii of a 69-byte blob",
        len(base64.b64decode(wrapped_b64)) == 69,
    )

    def load_kek(version: int) -> bytes:
        assert version == 1
        return kek

    recovered = decrypt_from_storage(aobj, wrapped_b64, load_kek)
    check("round-trip plaintext matches", recovered == plaintext)

    # Sensitivity gate: high encrypts, normal passes through untouched.
    gated_body, gated_wrapped = storage_body_and_wrapped_dek(
        plaintext, "high", kek, kek_version=1
    )
    check(
        "gate encrypts a high blob",
        gated_wrapped is not None and gated_body[:4] == b"AOBJ" and plaintext not in gated_body,
    )
    check(
        "gate round-trips a high blob",
        decrypt_from_storage(gated_body, gated_wrapped, load_kek) == plaintext,
    )
    normal_body, normal_wrapped = storage_body_and_wrapped_dek(
        plaintext, "normal", kek, kek_version=1
    )
    check(
        "gate leaves a normal blob as plaintext with no wrapped DEK",
        normal_body == plaintext and normal_wrapped is None,
    )

    # A wrong KEK from the resolver must fail the tag, not return garbage.
    from dek_envelope import EnvelopeError

    try:
        decrypt_from_storage(aobj, wrapped_b64, lambda _v: os.urandom(32))
        check("wrong KEK is rejected", False)
    except EnvelopeError:
        check("wrong KEK is rejected", True)

    # A tampered stored object must fail the tag.
    tampered = bytearray(aobj)
    tampered[-1] ^= 0x01
    try:
        decrypt_from_storage(bytes(tampered), wrapped_b64, load_kek)
        check("tampered stored object is rejected", False)
    except EnvelopeError:
        check("tampered stored object is rejected", True)

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
    print("usage: python envelope_store.py --self-test", file=sys.stderr)
    raise SystemExit(2)
