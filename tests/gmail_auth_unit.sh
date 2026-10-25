#!/usr/bin/env bash
#
# Unit test for scripts/gmail/gmail_auth.py (system_3 #8806-A1): the envelope
# round-trip of a synthetic authorised-user record under an EPHEMERAL KEK, the
# scope and client guards, the PKCE guard on the consent flow, the
# refresh-outcome classification and the no-secret-in-output rule. Runs in the
# same digest-pinned base as Dockerfile-Gmail with the same hash-locked
# packages (requirements/gmail.lock.txt), like tests/envelope_ingest_unit.sh,
# because the host python carries none of them and aspirant-deploy has no
# Makefile. No network use beyond that install; no real key material anywhere.
#
# Usage: ./tests/gmail_auth_unit.sh   (builds aspirant-gmail:local when missing; GMAIL_IMAGE overrides)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
IMAGE="${GMAIL_IMAGE:-aspirant-gmail:local}"
if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the gmail_auth self-test" >&2
  exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Building ${IMAGE} from Dockerfile-Gmail (digest-pinned base, hash-locked packages) ..."
  docker build -q -t "$IMAGE" -f Dockerfile-Gmail . >/dev/null || { echo "[FAIL] the image did not build from Dockerfile-Gmail (a hash mismatch refuses the install)"; exit 1; }
fi
echo "[PASS] ${IMAGE} builds from Dockerfile-Gmail with --require-hashes"
echo "Running the gmail_auth self-test in ${IMAGE} ..."
out="$(docker run --rm --entrypoint python -v "$PWD:/repo:ro" -w /repo "$IMAGE" scripts/gmail/gmail_auth.py --self-test 2>&1)" || { echo "$out"; echo "[FAIL] self-test exited non-zero"; exit 1; }
echo "$out"
fails=$(printf '%s\n' "$out" | grep -c '^\[FAIL\]' || true)
passes=$(printf '%s\n' "$out" | grep -c '^\[PASS\]' || true)
if printf '%s\n' "$out" | grep -q '^\[SKIP\] PKCE'; then
  echo "[FAIL] the PKCE check was skipped: google-auth-oauthlib did not install from the lock"; exit 1
fi
if printf '%s\n' "$out" | grep -q 'SELFTEST-REFRESH-TOKEN'; then
  echo "[FAIL] the self-test output printed the synthetic refresh token"; exit 1
fi
echo "[PASS] no token value in the self-test output"
if [[ "$fails" -ne 0 || "$passes" -lt 20 ]]; then echo "gmail_auth_unit: FAILED ($passes passed, $fails failed)"; exit 1; fi
echo "gmail_auth_unit: $((passes + 1)) passed, 0 failed"
