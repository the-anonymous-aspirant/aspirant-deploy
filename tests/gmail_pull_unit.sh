#!/usr/bin/env bash
#
# Unit test for scripts/gmail/gmail_pull.py (system_3 #8806-B1): full and
# incremental pulls over a synthetic mailbox in Gmail API response shapes
# (tests/fixtures/gmail/mailbox.json), the history-expired fallback, the commit
# order (the history id is written last), file modes, the refusals (no KEK,
# no token, re-consent) and the counts-only logging. Runs tests/gmail_pull_test.py
# in the same digest-pinned, hash-locked image as the tool (Dockerfile-Gmail),
# like tests/gmail_auth_unit.sh, because the host python has neither the google
# client libraries nor cryptography. No network, no real key material, no mail.
#
# Usage: ./tests/gmail_pull_unit.sh   (builds aspirant-gmail:local when missing; GMAIL_IMAGE overrides)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
IMAGE="${GMAIL_IMAGE:-aspirant-gmail:local}"
if ! command -v docker >/dev/null 2>&1; then
  echo "[SKIP] docker not available; cannot run the gmail_pull test" >&2
  exit 0
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "Building ${IMAGE} from Dockerfile-Gmail (digest-pinned base, hash-locked packages) ..."
  docker build -q -t "$IMAGE" -f Dockerfile-Gmail . >/dev/null || { echo "[FAIL] the image did not build from Dockerfile-Gmail"; exit 1; }
fi
echo "Running tests/gmail_pull_test.py in ${IMAGE} ..."
set +e
out="$(docker run --rm --network none --user "$(id -u):$(id -g)" -e HOME=/tmp -e PYTHONDONTWRITEBYTECODE=1 \
  --entrypoint python -v "$PWD:/repo:ro" -w /repo "$IMAGE" tests/gmail_pull_test.py 2>&1)"
rc=$?
set -e
echo "$out"
if [[ $rc -ne 0 ]]; then echo "gmail_pull_unit: FAILED (exit $rc)"; exit 1; fi
if printf '%s\n' "$out" | grep -qE 'skipped|SKIP'; then
  echo "[FAIL] a test was skipped; every check must run in the image"; exit 1
fi
if printf '%s\n' "$out" | grep -q 'PULLTEST-REFRESH-TOKEN'; then
  echo "[FAIL] the test output printed the synthetic refresh token"; exit 1
fi
ran=$(printf '%s\n' "$out" | sed -n 's/^Ran \([0-9]*\) tests.*/\1/p')
if [[ -z "$ran" || "$ran" -lt 12 ]]; then echo "[FAIL] expected at least 12 tests, ran '${ran:-none}'"; exit 1; fi
echo "gmail_pull_unit: ${ran} passed, 0 failed"
