#!/usr/bin/env bash
#
# Unit test for scripts/gmail/gmail_auth.py (system_3 #8806-A1): the envelope
# round-trip of a synthetic authorised-user record under an EPHEMERAL KEK, the
# scope and client guards, the refresh-outcome classification and the
# no-secret-in-output rule. Runs in python:3.12-slim with `cryptography`
# pip-installed, like tests/envelope_ingest_unit.sh, because the host python
# carries no cryptography and aspirant-deploy has no Makefile. No network use by
# the test itself beyond the pip install; no real key material anywhere.
#
# Usage: ./tests/gmail_auth_unit.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
IMAGE="${KEK_TEST_IMAGE:-python:3.12-slim}"
if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the gmail_auth self-test" >&2
  exit 0
fi
echo "Running the gmail_auth self-test in ${IMAGE} ..."
out="$(docker run --rm -v "$PWD:/repo:ro" -w /repo "$IMAGE" sh -c \
  'pip install -q --no-cache-dir cryptography==46.0.3 >/dev/null 2>&1 && python scripts/gmail/gmail_auth.py --self-test' 2>&1)" || { echo "$out"; echo "[FAIL] self-test exited non-zero"; exit 1; }
echo "$out"
fails=$(printf '%s\n' "$out" | grep -c '^\[FAIL\]' || true)
passes=$(printf '%s\n' "$out" | grep -c '^\[PASS\]' || true)
if printf '%s\n' "$out" | grep -q 'SELFTEST-REFRESH-TOKEN'; then
  echo "[FAIL] the self-test output printed the synthetic refresh token"; exit 1
fi
echo "[PASS] no token value in the self-test output"
if [[ "$fails" -ne 0 || "$passes" -lt 10 ]]; then echo "gmail_auth_unit: FAILED ($passes passed, $fails failed)"; exit 1; fi
echo "gmail_auth_unit: $((passes + 1)) passed, 0 failed"
