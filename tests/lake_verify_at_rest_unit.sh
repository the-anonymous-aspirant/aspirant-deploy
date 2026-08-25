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
