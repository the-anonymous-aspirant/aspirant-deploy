#!/usr/bin/env bash
set -euo pipefail

# Unit tests for scripts/lake/catalog.py — the lake catalog schema and the
# sensitivity-intake contract. Task #4270 (#4238-A2).
#
# Unlike tests/kek_envelope_unit.sh and tests/envelope_ingest_unit.sh, this one
# needs NO docker and NO pip install: catalog.py is deliberately stdlib-only, so
# its self-test runs on the cell's bare python. That is a property worth keeping
# — the rule this module encodes (fail closed to encrypted) is the one you most
# want re-checkable on a host where the container surface is unavailable.
#
# The interesting assertions are inside catalog.py's own --self-test, which this
# script runs. What it adds on top is the cross-file check the self-test cannot
# make: that the loader and the verifier actually go through the contract
# instead of carrying their own copy of the DDL, which is the exact drift #4270
# exists to prevent.
#
# Usage: ./tests/lake_catalog_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PY="${PYTHON:-python3}"
fails=0

pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

echo "catalog.py self-test:"
if "$PY" scripts/lake/catalog.py --self-test; then
  pass "catalog.py --self-test"
else
  fail "catalog.py --self-test"
fi

echo
echo "cross-file: the contract is actually used, not shadowed:"

# The failure this guards against is a quiet one. Someone edits the DDL inline in
# the loader "just this once" to add a column; the loader and the real ingest
# runner then disagree about the table, and nothing complains until a real load
# writes rows the explorer cannot read. So: no writer may spell out its own
# asset_inventory DDL.
for f in scripts/lake_skeleton_fixtures.py scripts/lake_skeleton_verify.py; do
  if grep -qE '^\s*sha256 VARCHAR, object_key VARCHAR' "$f"; then
    fail "$f re-declares the asset_inventory DDL inline" "it must use catalog.ASSET_INVENTORY_COLUMNS"
  else
    pass "$f does not re-declare the asset_inventory DDL"
  fi
done

for f in scripts/lake_skeleton_fixtures.py scripts/lake_skeleton_verify.py; do
  if grep -q '^import catalog' "$f"; then
    pass "$f imports the contract module"
  else
    fail "$f does not import the contract module"
  fi
done

# The loader reaches catalog.py only because compose mounts scripts/lake beside
# it. Without the mount the seed dies on ImportError inside a container, which
# is a slow and confusing way to find out.
if grep -q './scripts/lake:/work/lake:ro' docker-compose.lake-skeleton.yml; then
  pass "compose mounts scripts/lake into the client container"
else
  fail "compose does not mount scripts/lake" "the loader will ImportError at /work/lake"
fi

# Fail-closed means an undeclared blob is encrypted, so every fixture that means
# "normal" has to say so. If a call site loses its declaration the seed silently
# starts trying to envelope-encrypt a synthetic PNG — and, with no KEK set,
# refuses to seed at all.
declared=$(grep -c 'sensitivity="normal"' scripts/lake_skeleton_fixtures.py || true)
if [ "$declared" -ge 7 ]; then
  pass "every normal fixture declares its sensitivity ($declared sites)"
else
  fail "only $declared fixture call site(s) declare sensitivity=normal" "expected >= 7"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "[PASS] lake catalog contract: all checks passed"
  exit 0
fi
echo "[FAIL] lake catalog contract: $fails check(s) failed"
exit 1
