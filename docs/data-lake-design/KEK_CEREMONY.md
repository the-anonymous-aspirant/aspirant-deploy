# KEK ceremony — generation, off-cell custody, wrapped-DEK format

Implements **DATA_LAKE_DESIGN.md §9 layer 2** for phase **0b**. Task **#4133**
(`#4120-C`), child C of the 0b encryption epic **#4120**. This child ships the
key-encryption-key (KEK) for the envelope-encryption path, its off-cell custody
ceremony, and the exact on-the-wire format of a wrapped DEK. It **blocks child D**
(**#4134**, the ingest-runner envelope machinery + explorer read path), which
imports `scripts/kek/dek_envelope.py` rather than re-deriving the format.

> **Execution boundary.** Generating the real KEK and placing it in off-cell
> custody is an operator-invoked, production-secret, non-reversible ceremony.
> This document, `scripts/kek/gen-kek.sh`, `scripts/kek/dek_envelope.py`, and
> `tests/kek_envelope_unit.sh` are the *scriptable* pre-work and its
> verification; the live generation + custody + zeroization is run in one
> interactive window with the operator present, tracked as an `Operator-Hold:`
> on #4133. **No production KEK was generated while authoring this** — the
> self-test uses an ephemeral synthetic key that is discarded.

---

## 0. §9 verification (what this design is pinned to)

The canonical `DATA_LAKE_DESIGN.md` is substrate-resident, not an on-disk file.
Its §9 layer-2 text (read 2026-08-19 from the DB snapshot and the
aspirant-explorer `docs/DECISIONS.md` / `docs/SPEC.md` references) settles:

- **Two-key envelope.** A per-object **DEK** encrypts object bytes; a **KEK**
  wraps DEKs. The KEK is held **off-cell** and is never at rest on the cell's
  disks.
- **Custody (operator 2026-07-18 ruling):** hardware token **or** written-down,
  physically secured off-cell — explicitly *not* password-manager-only.
- **Cipher:** the DEK is **AES-256-GCM**. §9 pins **no** wrapping cipher
  distinct from the DEK cipher, so the wrap reuses AES-256-GCM (a single,
  well-understood AEAD primitive) rather than introducing AES-KW/RFC-3394 as a
  second primitive.
- **Crypto-erasure** is the §9 deletion story: destroy the wrapped DEK and the
  object is permanently unrecoverable without rewriting it — which is why the
  DEK is per-object and its only persistent copy is the wrapped form.

If a future revision of §9 pins a different wrapping cipher, bump `FMT_VERSION`
in `dek_envelope.py` and add a branch; the format is versioned for exactly this.

---

## 1. Cryptographic material

| Key | Size | Cipher | Lifetime | At rest? |
|---|---|---|---|---|
| **KEK** | 32 bytes (AES-256) | AES-256-GCM (wrap) | long-lived, rotated by version | **off-cell only** — hardware token or written down |
| **DEK** | 32 bytes (AES-256) | AES-256-GCM (object) | per object, seconds in memory | never in plaintext; stored **wrapped** in the asset-inventory row |

Both keys come from the OS CSPRNG (`getrandom(2)`, via `secrets.token_bytes` /
`os.urandom`). The KEK carries an integer **`kek_version`** so a future rotation
can re-wrap DEKs under a new KEK without a flag day (the wrapped-DEK header
records which KEK version wrapped it).

---

## 2. Generation ceremony

`scripts/kek/gen-kek.sh` generates one KEK and prints it — in base64, grouped
hex, and a non-secret SHA-256 fingerprint — to **stdout only**. It writes
nothing to disk, disables core dumps, and sets a private umask. The key exists
only in the terminal that ran it.

**Sequencing decision (task #4133).** The task text reads "run the gen script,
then post the Hold." Taken literally that leaves a live production KEK in cell
memory for the whole length of an operator hold — and the engineer must not
block on the pane. This playbook instead makes the **Operator-Hold gate the
whole ceremony**: the operator signals ready, and only then does
generation → custody placement → fingerprint verification → zeroization run in
one interactive window. This strictly shortens the live key's in-memory lifetime
and changes only *when* the key is generated, not what.

Concretely, during the interactive window:

```
scripts/kek/gen-kek.sh --kek-version 1
```

- Read the printed **fingerprint** aloud / record it in the task comment (it is
  one-way and safe to log).
- Place the key in custody **now** (§3).
- Read the key back from custody and confirm the fingerprint matches.
- Close the terminal / clear scrollback. Nothing on the cell retains the key.

---

## 3. Off-cell custody (operator-invoked)

Two accepted paths (operator 2026-07-18); the operator picks one:

1. **Hardware token.** Load the 32-byte KEK onto the token as a secret/key file.
   The cell reads it back only when the token is physically attached during a
   recovery/unwrap.
2. **Written down.** Transcribe the **grouped hex** onto paper and physically
   secure it off-cell (safe / lockbox). The grouped-hex encoding (16 groups of
   4) is chosen to survive hand-transcription; the fingerprint catches an error.

Either way the KEK is **full-entropy random key material**, not a
human-chosen passphrase — so there is no KDF and no passphrase-guessing surface.
(A future enhancement could encode the written-down form as a BIP-39 mnemonic
with its own checksum; out of scope for 0b.)

The physical placement is the operator's action. This task surfaces it as an
`Operator-Hold: KEK ceremony required` with a checklist and applies
`human-review-pending`.

---

## 4. Wrapped-DEK format

The canonical, executable definition is `scripts/kek/dek_envelope.py`. A wrapped
DEK is stored **base64** in the asset-inventory row (a text column). Raw layout,
**69 bytes** (base64 → 92 chars):

```
 offset  size  field       notes
 ------  ----  ----------  ---------------------------------------------
   0      4    magic       ASCII "WDEK" — guards against decoding a stray blob
   4      1    fmt_version 0x01
   5      4    kek_version uint32 big-endian — which KEK wrapped this DEK
   9     12    nonce       random 96-bit GCM nonce, one per wrap
  21     48    wrapped     AES-256-GCM(DEK) = 32-byte ciphertext ‖ 16-byte tag
```

The **9-byte header** (`magic ‖ fmt_version ‖ kek_version`) is passed as the GCM
**AAD**: it is integrity-protected but not encrypted, so tampering with the
`kek_version` (which would otherwise silently select the wrong key) fails the
authentication tag instead.

The **encrypted object** stored in Garage has a parallel 5-byte header:

```
 offset  size  field       notes
 ------  ----  ----------  ---------------------------------------------
   0      4    magic       ASCII "AOBJ"
   4      1    fmt_version 0x01
   5     12    nonce       random 96-bit GCM nonce, one per object
  17    ...    body        AES-256-GCM(plaintext) = ciphertext ‖ 16-byte tag
```

Reading the raw Garage object shows this header + ciphertext, never plaintext —
the §9 success criterion.

---

## 5. Recovery procedure (executable from this doc alone)

Given a wrapped DEK (from the inventory row) and an encrypted object (from
Garage), recover the plaintext:

1. **Base64-decode** the `wrapped_dek` column value → the 69-byte blob.
2. **Read `kek_version`** from the blob without any key
   (`wrapped_dek_kek_version(blob)`), so you know which KEK to fetch.
3. **Load that KEK from custody**: attach the hardware token, or read the
   written-down grouped hex and `bytes.fromhex(hex_without_spaces)`. Confirm the
   fingerprint `sha256(kek)[:8]` matches the value recorded at the ceremony.
4. **Unwrap the DEK:** `dek = unwrap_dek(blob, kek)`. A wrong KEK, wrong
   `kek_version`, or tampered blob raises `EnvelopeError` (a failed GCM tag) —
   it never returns garbage key bytes.
5. **Decrypt the object:** `plaintext = decrypt_object(object_bytes, dek)`.
6. **Zeroize** the KEK and DEK references and exit. Neither touched disk.

Minimal reference session (the ingest runner and explorer read path call the
same functions):

```python
import base64
from dek_envelope import unwrap_dek, decrypt_object, wrapped_dek_kek_version

blob = base64.b64decode(row["wrapped_dek"])
kek  = load_kek_from_custody(wrapped_dek_kek_version(blob))  # token / written-down
dek  = unwrap_dek(blob, kek)
plaintext = decrypt_object(garage_object_bytes, dek)
```

---

## 6. Recovery drill

Two levels, one automated now and one operator-invoked:

- **Format/code drill (automated, runs now):** `tests/kek_envelope_unit.sh`
  round-trips DEK → wrap → object-encrypt → decrypt → unwrap with an **ephemeral
  synthetic KEK** inside `python:3.11-slim`, plus wrong-key and tamper negative
  cases. This proves the format and the code end-to-end without any real key.
  Current result: **9 passed, 0 failed**.
- **Custody drill (operator-invoked, task step 4):** with the real KEK in
  off-cell custody, read it back from the operator-provided source (token
  attached, or operator types the written-down hex over SSH), unwrap a test DEK,
  decrypt a test envelope-encrypted object, and confirm the round-trip. Record
  the fingerprint match in the task comment. This is the half that needs the
  ceremony to have happened; it runs after the Operator-Hold clears.

---

## 7. What child D (#4134) consumes from here

- `scripts/kek/dek_envelope.py` — imported directly for wrap/unwrap and object
  encrypt/decrypt; the ingest runner encrypts `sensitivity=high` objects before
  the Garage `PUT` and writes the base64 wrapped DEK into the asset-inventory
  row; the explorer read path unwraps in memory to serve them.
- The `kek_version` → KEK-from-custody resolver is the one piece #4134 must wire
  to the actual custody medium the operator chose in §3.
