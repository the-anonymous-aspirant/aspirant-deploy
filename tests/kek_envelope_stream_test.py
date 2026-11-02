"""Streaming AOBJ writer: byte-identical to `encrypt_object`, bounded memory.

Task #9757 (#9546-A1). `scripts/kek/dek_envelope.py::encrypt_object` builds the
whole encrypted object in memory; `encrypt_object_stream` writes the same bytes
one chunk at a time so a multi-GB `sensitivity=high` upload can be wrapped on
the cell. This proves the two claims that change rests on:

1. **Same bytes.** For a fixed DEK and nonce the streamed output equals the
   one-shot layout (`header ‖ nonce ‖ AESGCM.encrypt(nonce, pt, header)`) at
   every chunk boundary that could go wrong, and `decrypt_object` opens it.
2. **Bounded memory.** 512 MiB of generated plaintext streams through with the
   process's peak RSS growing by about one chunk, not by the object's size.

Run in a container (the cell's host python has no `cryptography`):
`tests/kek_envelope_stream_unit.sh`. Synthetic keys only; nothing persists.
"""

from __future__ import annotations

import hashlib
import io
import os
import resource
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "scripts", "kek"))

from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa: E402

import dek_envelope as env  # noqa: E402

passed = 0
failed = 0


def check(label: str, cond: bool, detail: str = "") -> None:
    global passed, failed
    if cond:
        passed += 1
        print(f"[PASS] {label}")
    else:
        failed += 1
        print(f"[FAIL] {label} {detail}")


def one_shot(plaintext: bytes, dek: bytes, nonce: bytes) -> bytes:
    """`encrypt_object`'s construction with the nonce pinned (it draws its own)."""
    header = env._AOBJ_HEADER.pack(env.AOBJ_MAGIC, env.FMT_VERSION)
    return header + nonce + AESGCM(dek).encrypt(nonce, plaintext, header)


class _ZeroReader:
    """`size` bytes of a repeating generated pattern, produced on demand, so the
    large-input check never holds the input in memory either."""

    def __init__(self, size: int) -> None:
        self.left = size
        self.block = os.urandom(1024 * 1024)

    def read(self, n: int) -> bytes:
        if self.left <= 0:
            return b""
        n = min(n, self.left)
        self.left -= n
        reps, rem = divmod(n, len(self.block))
        return self.block * reps + self.block[:rem]


class _CountingSink:
    def __init__(self) -> None:
        self.n = 0
        self.head = b""
        self.tail = b""

    def write(self, b: bytes) -> int:
        if len(self.head) < 17:
            self.head = (self.head + b)[:17]
        self.tail = (self.tail + b)[-16:]
        self.n += len(b)
        return len(b)


def main() -> int:
    dek = env.generate_dek()
    nonce = os.urandom(env.NONCE_LEN)
    chunk = 64 * 1024

    # 1. Byte-identical at the boundaries: empty, one byte, one under/at/over a
    #    chunk, several chunks, and a few MiB.
    for size in (0, 1, chunk - 1, chunk, chunk + 1, 3 * chunk + 7, 3 * 1024 * 1024 + 5):
        pt = os.urandom(size)
        out = io.BytesIO()
        n = env._encrypt_object_stream(io.BytesIO(pt), out, dek, nonce, chunk_size=chunk)
        streamed = out.getvalue()
        check(f"size {size}: streamed bytes == one-shot layout", streamed == one_shot(pt, dek, nonce))
        check(f"size {size}: returns the plaintext length", n == size, f"got {n}")
        check(f"size {size}: decrypt_object opens it", env.decrypt_object(streamed, dek) == pt)

    # 2. The public writer draws a fresh nonce each call, and still decrypts.
    pt = os.urandom(200_000)
    a, b = io.BytesIO(), io.BytesIO()
    env.encrypt_object_stream(io.BytesIO(pt), a, dek, chunk_size=chunk)
    env.encrypt_object_stream(io.BytesIO(pt), b, dek, chunk_size=chunk)
    check("public writer: fresh nonce per call", a.getvalue()[5:17] != b.getvalue()[5:17])
    check("public writer: output decrypts", env.decrypt_object(a.getvalue(), dek) == pt)

    # 3. The plaintext hash hook sees exactly the plaintext.
    h = hashlib.sha256()
    env.encrypt_object_stream(io.BytesIO(pt), io.BytesIO(), dek, chunk_size=chunk, plaintext_hash=h)
    check("plaintext_hash equals sha256(plaintext)", h.hexdigest() == hashlib.sha256(pt).hexdigest())

    # 4. Bad inputs are refused, not silently mis-encrypted.
    for label, call in (
        ("short DEK", lambda: env.encrypt_object_stream(io.BytesIO(b"x"), io.BytesIO(), dek[:16])),
        ("short nonce", lambda: env._encrypt_object_stream(io.BytesIO(b"x"), io.BytesIO(), dek, nonce[:8], chunk_size=chunk)),
        ("zero chunk", lambda: env.encrypt_object_stream(io.BytesIO(b"x"), io.BytesIO(), dek, chunk_size=0)),
    ):
        try:
            call()
            check(f"{label} is refused", False)
        except env.EnvelopeError:
            check(f"{label} is refused", True)

    # 5. A tampered streamed object fails the tag like a one-shot one.
    out = io.BytesIO()
    env.encrypt_object_stream(io.BytesIO(pt), out, dek, chunk_size=chunk)
    bad = bytearray(out.getvalue())
    bad[len(bad) // 2] ^= 0x01
    try:
        env.decrypt_object(bytes(bad), dek)
        check("tampered streamed object is rejected", False)
    except env.EnvelopeError:
        check("tampered streamed object is rejected", True)

    # 6. Bounded memory: 512 MiB through the default 8 MiB chunk. ru_maxrss is
    #    KiB on Linux. One-shot would need >= 1 GiB (plaintext + ciphertext).
    size = 512 * 1024 * 1024
    before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    sink = _CountingSink()
    n = env.encrypt_object_stream(_ZeroReader(size), sink, dek)
    after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    growth_mib = (after - before) / 1024
    print(f"       512 MiB streamed: peak RSS {before / 1024:.1f} -> {after / 1024:.1f} MiB "
          f"(+{growth_mib:.1f} MiB), wrote {sink.n} bytes")
    check("512 MiB: every plaintext byte read", n == size)
    check("512 MiB: output is header + nonce + body + tag",
          sink.n == 5 + env.NONCE_LEN + size + env.TAG_LEN and sink.head[:4] == env.AOBJ_MAGIC)
    check("512 MiB: peak RSS grows by under 64 MiB", growth_mib < 64, f"(+{growth_mib:.1f} MiB)")

    print()
    if failed:
        print(f"FAILED: {failed} failed, {passed} passed")
        return 1
    print(f"{passed} passed, 0 failed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
