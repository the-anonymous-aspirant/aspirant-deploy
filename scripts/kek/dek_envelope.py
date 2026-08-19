"""Layer-2 envelope encryption: the wrapped-DEK format and object crypto.

Implements **DATA_LAKE_DESIGN.md §9 layer 2** for phase **0b**. Task **#4133**
(`#4120-C`), child C of the 0b encryption epic **#4120**. This module is the
*canonical, executable* form of the wrapped-DEK format documented in
`docs/data-lake-design/KEK_CEREMONY.md`; child D (**#4134**, the ingest runner's
envelope machinery + the explorer read path) imports these functions rather than
re-deriving the byte layout, so the format has exactly one source of truth.

Two keys, per §9:

  * **KEK** (key-encryption-key) — 32 bytes, AES-256. Held *off-cell* (hardware
    token or written-down, operator 2026-07-18 ruling). Never at rest on the
    cell's disks. Wraps DEKs; never touches object bytes.
  * **DEK** (data-encryption-key) — 32 bytes, AES-256, *per object*. Random,
    used once to encrypt one object, then wrapped under the KEK and stored
    (wrapped) in the asset-inventory row. The plaintext DEK lives only in
    memory, only for as long as one encrypt or one decrypt takes.

Both wrap and object encryption use **AES-256-GCM** (AEAD: confidentiality +
integrity in one primitive). §9 pins no wrapping cipher distinct from the DEK
cipher, so the wrap reuses AES-256-GCM rather than introducing a second
primitive (verified against the §9 text 2026-08-19, task #4133).

Crypto-erasure (§9 deletion story): destroy the wrapped DEK in the inventory row
and the object in Garage becomes permanently unrecoverable, without rewriting
the object. That property is why the DEK is per-object and the wrap is the only
copy of it.

Dependency: `cryptography` (the ingest runner already carries it). The cell's
host python does not; run the self-test in a container — see
`tests/kek_envelope_unit.sh`.

    python scripts/kek/dek_envelope.py --self-test
"""

from __future__ import annotations

import os
import struct

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

# --- constants ---------------------------------------------------------------

KEY_LEN = 32   # AES-256
NONCE_LEN = 12  # 96-bit GCM nonce, the standard/recommended size
TAG_LEN = 16   # 128-bit GCM tag (appended to the ciphertext by AESGCM)

WDEK_MAGIC = b"WDEK"   # wrapped-DEK blob (rides in the asset-inventory row)
AOBJ_MAGIC = b"AOBJ"   # encrypted object (the bytes PUT to Garage)
FMT_VERSION = 1        # bump only on an incompatible layout change

# Header of a wrapped-DEK blob: magic(4) + fmt_version(1) + kek_version(uint32 BE)
# = 9 bytes, authenticated (as GCM AAD) but not encrypted. Binding the header as
# AAD means a tampered kek_version or magic fails the tag check instead of
# silently selecting the wrong key.
_WDEK_HEADER = struct.Struct(">4sBI")   # 9 bytes
# Header of an encrypted object: magic(4) + fmt_version(1) = 5 bytes, AAD.
_AOBJ_HEADER = struct.Struct(">4sB")    # 5 bytes


class EnvelopeError(Exception):
    """Malformed blob, wrong key, or a failed authentication tag."""


# --- key + DEK generation ----------------------------------------------------

def generate_dek() -> bytes:
    """A fresh per-object 32-byte DEK from the OS CSPRNG (getrandom)."""
    return os.urandom(KEY_LEN)


# --- wrapped-DEK format ------------------------------------------------------

def wrap_dek(dek: bytes, kek: bytes, kek_version: int = 1) -> bytes:
    """Wrap a DEK under the KEK. Returns the raw wrapped-DEK blob.

    Layout (69 bytes, base64 -> 92 chars for the inventory row):

        magic     4   b"WDEK"
        fmt_ver   1   0x01
        kek_ver   4   uint32 BE   -- which KEK wrapped this (rotation)
        nonce    12   random per wrap
        wrapped  48   AES-256-GCM(dek)  == 32 ciphertext + 16 tag

    The 9-byte header (magic+fmt_ver+kek_ver) is the GCM AAD, so it is
    integrity-protected without being encrypted.
    """
    if len(dek) != KEY_LEN:
        raise EnvelopeError(f"DEK must be {KEY_LEN} bytes, got {len(dek)}")
    if len(kek) != KEY_LEN:
        raise EnvelopeError(f"KEK must be {KEY_LEN} bytes, got {len(kek)}")
    header = _WDEK_HEADER.pack(WDEK_MAGIC, FMT_VERSION, kek_version)
    nonce = os.urandom(NONCE_LEN)
    wrapped = AESGCM(kek).encrypt(nonce, dek, header)
    return header + nonce + wrapped


def unwrap_dek(blob: bytes, kek: bytes) -> bytes:
    """Recover the plaintext DEK from a wrapped-DEK blob using the KEK.

    Raises EnvelopeError on a bad magic/version, a truncated blob, or a failed
    tag (wrong KEK or tampered header/ciphertext).
    """
    if len(blob) < _WDEK_HEADER.size + NONCE_LEN + KEY_LEN + TAG_LEN:
        raise EnvelopeError("wrapped-DEK blob is truncated")
    if len(kek) != KEY_LEN:
        raise EnvelopeError(f"KEK must be {KEY_LEN} bytes, got {len(kek)}")
    header = blob[: _WDEK_HEADER.size]
    magic, fmt_ver, _kek_version = _WDEK_HEADER.unpack(header)
    if magic != WDEK_MAGIC:
        raise EnvelopeError("not a wrapped-DEK blob (bad magic)")
    if fmt_ver != FMT_VERSION:
        raise EnvelopeError(f"unsupported wrapped-DEK format version {fmt_ver}")
    nonce = blob[_WDEK_HEADER.size : _WDEK_HEADER.size + NONCE_LEN]
    wrapped = blob[_WDEK_HEADER.size + NONCE_LEN :]
    try:
        dek = AESGCM(kek).decrypt(nonce, wrapped, header)
    except InvalidTag as exc:
        raise EnvelopeError(
            "unwrap failed the authentication tag "
            "(wrong KEK, wrong kek_version, or a tampered blob)"
        ) from exc
    if len(dek) != KEY_LEN:
        raise EnvelopeError("unwrapped DEK has the wrong length")
    return dek


def wrapped_dek_kek_version(blob: bytes) -> int:
    """Read the kek_version from a wrapped-DEK blob without the KEK.

    Lets the read path pick which KEK to load from custody before it has any
    key material in hand.
    """
    if len(blob) < _WDEK_HEADER.size:
        raise EnvelopeError("wrapped-DEK blob is truncated")
    magic, _fmt_ver, kek_version = _WDEK_HEADER.unpack(blob[: _WDEK_HEADER.size])
    if magic != WDEK_MAGIC:
        raise EnvelopeError("not a wrapped-DEK blob (bad magic)")
    return kek_version


# --- object encryption -------------------------------------------------------

def encrypt_object(plaintext: bytes, dek: bytes) -> bytes:
    """Encrypt one object under its DEK. Returns the bytes to PUT to Garage.

    Layout:

        magic     4   b"AOBJ"
        fmt_ver   1   0x01
        nonce    12   random per object
        body    ...   AES-256-GCM(plaintext)  == ciphertext + 16 tag

    The 5-byte header is the GCM AAD.
    """
    if len(dek) != KEY_LEN:
        raise EnvelopeError(f"DEK must be {KEY_LEN} bytes, got {len(dek)}")
    header = _AOBJ_HEADER.pack(AOBJ_MAGIC, FMT_VERSION)
    nonce = os.urandom(NONCE_LEN)
    body = AESGCM(dek).encrypt(nonce, plaintext, header)
    return header + nonce + body


def decrypt_object(blob: bytes, dek: bytes) -> bytes:
    """Decrypt a Garage object blob using its (already-unwrapped) DEK."""
    if len(blob) < _AOBJ_HEADER.size + NONCE_LEN + TAG_LEN:
        raise EnvelopeError("object blob is truncated")
    if len(dek) != KEY_LEN:
        raise EnvelopeError(f"DEK must be {KEY_LEN} bytes, got {len(dek)}")
    header = blob[: _AOBJ_HEADER.size]
    magic, fmt_ver = _AOBJ_HEADER.unpack(header)
    if magic != AOBJ_MAGIC:
        raise EnvelopeError("not an encrypted object (bad magic)")
    if fmt_ver != FMT_VERSION:
        raise EnvelopeError(f"unsupported object format version {fmt_ver}")
    nonce = blob[_AOBJ_HEADER.size : _AOBJ_HEADER.size + NONCE_LEN]
    body = blob[_AOBJ_HEADER.size + NONCE_LEN :]
    try:
        return AESGCM(dek).decrypt(nonce, body, header)
    except InvalidTag as exc:
        raise EnvelopeError(
            "object decryption failed the authentication tag "
            "(wrong DEK or a tampered object)"
        ) from exc


# --- self-test (the scriptable recovery drill) -------------------------------

def _self_test() -> int:
    """Round-trip the whole envelope with an EPHEMERAL synthetic KEK.

    Proves the format and this code end-to-end without any real key material:
    the KEK here is generated in-process and discarded. The *operator's* real
    recovery drill (task step 4) runs this same path with the off-cell KEK read
    from custody — see KEK_CEREMONY.md.
    """
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

    # Ephemeral, synthetic — never persisted, never the production KEK.
    kek = os.urandom(KEY_LEN)
    plaintext = b"SYNTHETIC -- kek envelope self-test object " + os.urandom(4096)

    # Happy path: DEK -> wrap -> object encrypt -> object decrypt -> unwrap.
    dek = generate_dek()
    check("DEK is 32 bytes", len(dek) == KEY_LEN)

    wrapped = wrap_dek(dek, kek, kek_version=1)
    check("wrapped-DEK blob is 69 bytes", len(wrapped) == 69)
    check("kek_version reads back without the KEK",
          wrapped_dek_kek_version(wrapped) == 1)

    obj = encrypt_object(plaintext, dek)
    check("encrypted object is not plaintext",
          plaintext not in obj and obj[:4] == AOBJ_MAGIC)

    # Recovery: unwrap the DEK, then decrypt the object.
    recovered_dek = unwrap_dek(wrapped, kek)
    check("unwrapped DEK equals the original DEK", recovered_dek == dek)

    recovered = decrypt_object(obj, recovered_dek)
    check("round-trip plaintext matches", recovered == plaintext)

    # Negative: a wrong KEK must fail the tag, not return garbage.
    try:
        unwrap_dek(wrapped, os.urandom(KEY_LEN))
        check("wrong KEK is rejected", False)
    except EnvelopeError:
        check("wrong KEK is rejected", True)

    # Negative: a tampered wrapped-DEK header must fail the tag.
    tampered = bytearray(wrapped)
    tampered[8] ^= 0x01  # flip a bit in the kek_version (part of the AAD)
    try:
        unwrap_dek(bytes(tampered), kek)
        check("tampered wrapped-DEK header is rejected", False)
    except EnvelopeError:
        check("tampered wrapped-DEK header is rejected", True)

    # Negative: a tampered object body must fail the tag.
    tampered_obj = bytearray(obj)
    tampered_obj[-1] ^= 0x01
    try:
        decrypt_object(bytes(tampered_obj), dek)
        check("tampered object ciphertext is rejected", False)
    except EnvelopeError:
        check("tampered object ciphertext is rejected", True)

    print()
    if failed:
        print(f"FAILED: {failed} failed, {passed} passed")
        return 1
    print(f"{passed} passed, 0 failed")
    return 0


if __name__ == "__main__":
    import sys

    if "--self-test" in sys.argv[1:]:
        raise SystemExit(_self_test())
    print(__doc__)
    print("Run the round-trip self-test with:  --self-test")
    raise SystemExit(2)
