#!/usr/bin/env bash
#
# Test surface for the Gmail lake ingest (system_3 #8810, #8806-B2).
#
#   1. tests/gmail_lake_ingest_roundtrip.py — B1's export through the real
#      ingest runner against moto S3 and a real DuckDB, then verify-at-rest over
#      the bucket. Needs cryptography + boto3 + moto + duckdb, none of which the
#      cell's host python carries, so it runs in python:3.11-slim exactly like
#      tests/lake_ingest_unit.sh (aspirant-deploy has no Makefile; the container
#      is the test surface, per CONVENTIONS.md).
#
#   2. host checks, no docker: the one-prompt wrapper's own unit test
#      (tests/gmail_pull_and_ingest_unit.sh) and the structural claim that the
#      wrapper drives the two existing tools rather than a copy of either.
#
# Every KEK exercised here is an ephemeral synthetic key generated inside the
# test process, and every message is the synthetic fixture mailbox. No
# production key material is touched and nothing is persisted.
#
# Usage: ./tests/gmail_lake_ingest_unit.sh   (LAKE_TEST_IMAGE overrides the base image)
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

IMAGE="${LAKE_TEST_IMAGE:-python:3.11-slim}"
fails=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

echo "== host: the wrapper drives the existing tools"
w=scripts/gmail/gmail_pull_and_ingest.sh
grep -q 'scripts/gmail/gmail.sh pull' "$w" && pass "pull half is scripts/gmail/gmail.sh pull" || fail "pull half"
grep -q 'scripts/lake-skeleton.sh ingest' "$w" && pass "ingest half is scripts/lake-skeleton.sh ingest" || fail "ingest half"
grep -q 'scripts/lake-skeleton.sh verify-at-rest' "$w" && pass "--verify is scripts/lake-skeleton.sh verify-at-rest" || fail "verify half"
# An expansion of the variable inside an echo/printf would print the key; the
# variable's NAME in a message is fine (the refusal line says how to set it).
if grep -nE '(echo|printf)[^\n]*\$\{?LAKE_KEK_HEX|set -x' "$w" >/dev/null; then fail "the wrapper never prints the KEK"; else pass "the wrapper never prints the KEK"; fi
grep -q 'read -rs' "$w" && pass "the KEK is read hidden" || fail "hidden read"

echo "== host: the wrapper unit test"
if bash tests/gmail_pull_and_ingest_unit.sh > /tmp/gmail_wrapper_unit.$$ 2>&1; then
  pass "tests/gmail_pull_and_ingest_unit.sh ($(grep -c '\[PASS\]' /tmp/gmail_wrapper_unit.$$) checks)"
else
  fail "tests/gmail_pull_and_ingest_unit.sh"; cat /tmp/gmail_wrapper_unit.$$
fi
rm -f /tmp/gmail_wrapper_unit.$$

# Pinned to the lake client image's own versions (Dockerfile-LakeDuckDB's
# LAKE_REQUIREMENTS line): an unpinned duckdb wheel died with "Illegal
# instruction" on the cell (2026-11-01), and the runner that will load real
# mail runs on exactly these versions anyway.
echo "== container: B1's export through the runner, verify-at-rest over the bucket (${IMAGE})"
if docker run --rm \
    -v "$PWD:/repo:ro" -w /repo -e HOME=/tmp -e PYTHONDONTWRITEBYTECODE=1 \
    "$IMAGE" \
    sh -c "pip install --quiet --disable-pip-version-check --timeout 120 --retries 5 \
        cryptography==46.0.3 boto3==1.40.47 duckdb==1.5.4 moto \
      && python tests/gmail_lake_ingest_roundtrip.py"; then
  pass "tests/gmail_lake_ingest_roundtrip.py"
else
  fail "tests/gmail_lake_ingest_roundtrip.py"
fi

echo
if [[ $fails -eq 0 ]]; then echo "gmail_lake_ingest_unit: all checks passed"; else echo "gmail_lake_ingest_unit: $fails check(s) FAILED"; exit 1; fi
