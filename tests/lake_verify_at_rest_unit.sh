#!/usr/bin/env bash
#
# Test surface for the at-rest verification harness, scripts/lake_verify_at_rest.py.
# Task #4299 (#4273-A1), layer 2 of the phase-1 real-data epic #4238.
#
# Three suites, and the split is the point:
#
#   1. the harness's own --self-test, on the CELL'S BARE PYTHON. No docker, no
#      cryptography, no lake. That is deliberate and it is the same property
#      scripts/lake/catalog.py protects: the tool that answers "is the
#      operator's data encrypted on disk?" must be re-checkable on a host where
#      the container surface is unavailable, because "the container is broken"
#      is exactly when somebody wants to ask.
#
#   2. static checks, on the host. They assert what the self-test structurally
#      cannot: that the harness consumes the shared contracts instead of forking
#      them, and that it reads the object store DIRECTLY rather than through the
#      explorer's decrypting read path — a harness that read through the
#      decryptor would report a plaintext write as encrypted, which is the one
#      failure it exists to catch.
#
#   3. the header drift guard, in python:3.11-slim with cryptography installed.
#      The harness mirrors dek_envelope's two magics and two struct formats so
#      it can run on the pinned client image, which predates the cryptography
#      dependency (#4290). A mirror on trust is a fork; this is what makes it a
#      mirror.
#
# Every byte exercised here is synthetic and no key material is touched: the
# self-test builds structurally-faithful AOBJ/WDEK blobs without encrypting
# anything, precisely so it needs no crypto.
#
# Usage: ./tests/lake_verify_at_rest_unit.sh
#   Suite 3 needs docker. Set LAKE_TEST_IMAGE to override the base image.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PY="${PYTHON:-python3}"
IMAGE="${LAKE_TEST_IMAGE:-python:3.11-slim}"
HARNESS=scripts/lake_verify_at_rest.py
fails=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

# --- suite 1 (host, no docker): the harness proved by making it fail ---------

echo "lake_verify_at_rest.py self-test (bare python, no cryptography needed):"
if "$PY" "$HARNESS" --self-test; then
  pass "$HARNESS --self-test"
else
  fail "$HARNESS --self-test"
fi

# A harness that always passes is not a harness. Its own exit code has to move.
echo
echo "the self-test can fail:"
if "$PY" - <<'PROBE'; then
import importlib.util, sys
spec = importlib.util.spec_from_file_location("h", "scripts/lake_verify_at_rest.py")
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)

# A row that is unambiguously wrong: high sensitivity, plaintext on disk.
row = {
    "sha256": "0" * 64, "object_key": "k", "source_path": "/planted",
    "sensitivity": "high", "wrapped_dek": None, "kek_version": None,
}
findings = h.verify([row], lambda key: b"%PDF-1.4 in the clear", None)
green, counts = h.verdict(findings)
sys.exit(0 if (not green and counts[h.FAIL] > 0) else 1)
PROBE
  pass "a planted plaintext-under-high row drives the verdict to NOT GREEN"
else
  fail "a planted plaintext-under-high row did not fail the verdict" \
       "the harness cannot report what it cannot detect"
fi

# --- suite 2 (host): the harness consumes contracts and reads the disk -------

echo
echo "static: contracts consumed, not forked:"

if grep -q '^import catalog' "$HARNESS"; then
  pass "the harness imports the catalog contract"
else
  fail "the harness does not import the catalog contract" \
       "the sensitivity vocabulary must come from scripts/lake/catalog.py"
fi

if grep -qE 'AESGCM|Cipher\(|^from cryptography' "$HARNESS"; then
  fail "the harness contains cryptography primitives" \
       "all object crypto belongs in scripts/kek/dek_envelope.py (#4133)"
else
  pass "the harness contains no cryptography primitives of its own"
fi

# The load-bearing one. §9's guarantee is about the bytes on disk; the explorer
# decrypts on read, so a harness that fetched through it would show a plaintext
# write as a correctly encrypted object. It must speak S3 directly.
# Matched on what the code DOES, not on the word "explorer" — the harness's own
# docstring says it must not read through the explorer, and a naive negative
# grep flags that sentence as the violation it warns about.
if grep -qE '\bs3\.get_object\(' "$HARNESS"; then
  pass "the harness reads stored objects with a direct S3 get_object"
else
  fail "the harness does not call s3.get_object" \
       "the bytes must come from the object store, not from a service that may decrypt"
fi

if grep -qE '^\s*(import|from)\s+(requests|httpx|urllib)\b' "$HARNESS"; then
  fail "the harness imports an HTTP client" \
       "reading through the explorer's decrypting read path would show a plaintext write as ciphertext"
else
  pass "the harness has no HTTP client, so it cannot reach a decrypting read path"
fi

# Read-only catalog attachment: a verifier that could write could repair what it
# is supposed to report, and the run where that matters is the one deciding
# whether real data is safe.
if grep -q 'READ_ONLY' "$HARNESS"; then
  pass "the catalog is attached READ_ONLY"
else
  fail "the catalog attachment is not READ_ONLY" \
       "a verification harness must not be able to write what it checks"
fi

# A skipped proof is not a passing one. This is the rule #4238-D1 leans on.
if grep -q 'counts\[SKIP\] == 0' "$HARNESS"; then
  pass "a SKIP keeps the verdict off green"
else
  fail "a SKIP may be folding into a green verdict" \
       "check 5 skips whenever no KEK is in custody"
fi

# #4524 (#4301 F4/F5): check 7 must read the bucket itself — the catalog is what
# every other check iterates, so an uncatalogued blob is invisible to them — and
# the KEK in custody must be checked against the ceremony fingerprint, so a
# mistyped key is an input error and not a false data-loss alarm on every row.
if grep -qE 'list_objects_v2' "$HARNESS"; then
  pass "check 7 lists the blob prefix from the bucket, not from the catalog"
else
  fail "the harness never lists the bucket" \
       "an object with no catalog row is unreachable by catalog-driven checks (#4301 F4)"
fi

if grep -qE 'load_kek_from_env\(expected_fingerprint=' "$HARNESS"; then
  pass "the KEK in custody is checked against LAKE_KEK_FINGERPRINT"
else
  fail "the harness loads the KEK without its fingerprint" \
       "a wrong key reads as data loss on every high row instead of as an input error (#4301 F5)"
fi

# And the harness must go red on the two #4301 lies the self-test cannot plant
# through a single row: an empty catalog, and a bucket object the catalog does
# not know about.
echo
echo "the #4301 green-lies are red:"
if "$PY" - <<'LIES'; then
import importlib.util, sys
spec = importlib.util.spec_from_file_location("h", "scripts/lake_verify_at_rest.py")
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
empty_green, _ = h.verdict(h.verify([], lambda key: b"", None))
row = {"sha256": "0" * 64, "object_key": "bronze/blobs/k", "source_path": "/p",
       "sensitivity": "normal", "wrapped_dek": None, "kek_version": None}
body = b"x"
import hashlib
row["sha256"] = hashlib.sha256(body).hexdigest()
orphan_green, _ = h.verdict(h.verify([row], lambda key: body, None,
                                     stored_keys=["bronze/blobs/k", "bronze/blobs/orphan"]))
clean_green, _ = h.verdict(h.verify([row], lambda key: body, None,
                                    stored_keys=["bronze/blobs/k"]))
sys.exit(0 if (not empty_green and not orphan_green and clean_green) else 1)
LIES
  pass "an empty catalog and an uncatalogued object both drive the verdict to NOT GREEN"
else
  fail "an empty catalog or an uncatalogued object still reads green" "#4301 F1 / F4"
fi

# --- suite 3 (container): the mirrored header constants have not drifted -----

echo
if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the header drift guard" >&2
  fails=$((fails + 1))
else
  # Both import branches have to be covered, and which one the HOST takes
  # depends on what happens to be installed there — today the cell's python3 has
  # no cryptography, so suite 1 exercises the fallback, but that is an accident
  # of the host rather than a property of the test. Pin it: a slim image with
  # nothing installed must take the fallback and still pass.
  echo "Fallback branch in ${IMAGE} with NO cryptography (the pinned client image's situation):"
  docker run --rm -v "$PWD:/repo:ro" -w /repo "$IMAGE" python - <<'FALLBACK' \
    && pass "the harness runs on an image that cannot import dek_envelope" \
    || fail "the harness does not survive a missing cryptography" \
            "the pinned client image is exactly this environment (#4290)"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("h", "scripts/lake_verify_at_rest.py")
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
if h.CRYPTO_AVAILABLE:
    print("  cryptography was importable here; this branch proves nothing")
    sys.exit(1)
sys.exit(0 if h._self_test() else 1)
FALLBACK

  echo
  echo "Header drift guard in ${IMAGE} (needs cryptography to import dek_envelope):"
  docker run --rm -v "$PWD:/repo:ro" -w /repo "$IMAGE" \
    sh -c "pip install --quiet --disable-pip-version-check cryptography \
      && python - <<'DRIFT'
import importlib.util, sys
sys.path.insert(0, 'scripts/kek')
sys.path.insert(0, 'scripts/lake')
import dek_envelope

spec = importlib.util.spec_from_file_location('h', 'scripts/lake_verify_at_rest.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)

problems = []
if not h.CRYPTO_AVAILABLE:
    problems.append('dek_envelope was importable here but the harness did not use it')
for name, mirrored, canonical in (
    ('WDEK magic', h._MIRROR_WDEK_MAGIC, dek_envelope.WDEK_MAGIC),
    ('AOBJ magic', h._MIRROR_AOBJ_MAGIC, dek_envelope.AOBJ_MAGIC),
    ('WDEK header format', h._MIRROR_WDEK_HEADER.format, dek_envelope._WDEK_HEADER.format),
    ('AOBJ header format', h._MIRROR_AOBJ_HEADER.format, dek_envelope._AOBJ_HEADER.format),
):
    if mirrored != canonical:
        problems.append(f'{name}: mirror {mirrored!r} != canonical {canonical!r}')

# And the parse agrees with dek_envelope's own, on a real wrapped DEK.
wrapped = dek_envelope.wrap_dek(dek_envelope.generate_dek(), bytes(range(32)), 7)
if h.wdek_header_kek_version(wrapped) != dek_envelope.wrapped_dek_kek_version(wrapped):
    problems.append('the mirrored header parse disagrees with dek_envelope')

for problem in problems:
    print('  [FAIL] ' + problem)
if not problems:
    print('  [PASS] the mirrored envelope constants still match dek_envelope')

# #4524 (#4301 F5): the custody seam honours the ceremony fingerprint. A KEK
# whose fingerprint does not match is rejected as an input error BEFORE any
# row is judged; a matching one yields an unwrap that round-trips a real DEK;
# and with the KEK in hand the decrypt seam is the canonical decrypt_object.
import os, kek_loader
kek = bytes(range(32))
os.environ['LAKE_KEK_HEX'] = kek.hex()
os.environ['LAKE_KEK_FINGERPRINT'] = 'ffffffffffffffff'
try:
    h._custody_unwrap()
    problems.append('a KEK with the wrong fingerprint was accepted')
except kek_loader.KekLoadError:
    print('  [PASS] a KEK that does not match LAKE_KEK_FINGERPRINT is rejected before use')
os.environ['LAKE_KEK_FINGERPRINT'] = kek_loader.fingerprint(kek)
unwrap = h._custody_unwrap()
dek = dek_envelope.generate_dek()
if unwrap is None or unwrap(dek_envelope.wrap_dek(dek, kek, 1)) != dek:
    problems.append('a KEK matching LAKE_KEK_FINGERPRINT did not yield a working unwrap')
else:
    print('  [PASS] a KEK matching LAKE_KEK_FINGERPRINT unwraps a real wrapped DEK')
if h._custody_decrypt() is not dek_envelope.decrypt_object:
    problems.append('the decrypt seam is not dek_envelope.decrypt_object')
else:
    print('  [PASS] check 6 decrypts through dek_envelope.decrypt_object, not a copy')
# And end to end on real bytes: a real envelope of the WRONG plaintext under a
# row passes 2-5 and fails 6; the right plaintext is green.
import hashlib
plaintext = b'SYNTHETIC real-crypto fixture'
row = {'sha256': hashlib.sha256(plaintext).hexdigest(), 'object_key': 'k',
       'source_path': '/fixture', 'sensitivity': 'high', 'kek_version': 1,
       'wrapped_dek': __import__('base64').b64encode(dek_envelope.wrap_dek(dek, kek, 1)).decode()}
right = dek_envelope.encrypt_object(plaintext, dek)
wrong = dek_envelope.encrypt_object(b'SYNTHETIC some other bytes', dek)
g_right, _ = h.verdict(h.verify([row], lambda k: right, unwrap, decrypt=h._custody_decrypt(), stored_keys=['k']))
f_wrong = h.verify([row], lambda k: wrong, unwrap, decrypt=h._custody_decrypt(), stored_keys=['k'])
g_wrong, _ = h.verdict(f_wrong)
six = [f.status for f in f_wrong if f.check == h.CHECK_DECRYPTS_TO_CONTENT]
if g_right and not g_wrong and six == [h.FAIL]:
    print('  [PASS] on real AES-GCM bytes: the right ciphertext is green, another plaintext\'s valid envelope fails check 6')
else:
    problems.append(f'real-crypto end to end: right={g_right} wrong={g_wrong} check6={six}')
for problem in problems:
    print('  [FAIL] ' + problem)
sys.exit(1 if problems else 0)
DRIFT" || fails=$((fails + 1))
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "[PASS] lake at-rest harness: all checks passed"
  exit 0
fi
echo "[FAIL] lake at-rest harness: $fails check(s) failed"
exit 1
