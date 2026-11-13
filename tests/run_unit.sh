#!/usr/bin/env bash
#
# aspirant-deploy's verify command (system_3 #10799-A3): runs every
# tests/*_unit.sh and exits non-zero if any fails.
#
#   bash tests/run_unit.sh
#
# Before this the repo had no single verify command. Each PR's verify chained
# suites by hand, so nothing guaranteed that tests/changelog_unit.sh ran, and
# a malformed changelog fragment could merge (aspirant-server merged nine in
# a row on 2026-11-12). Every suite runs here, the changelog suite included.
# A new *_unit.sh joins without an edit to this file.
#
# On the cell, all of them take about ten minutes; db_roles_unit.sh (its own
# throwaway Postgres) takes about three of those (measured 2026-11-13).

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Suites that fail on main for a reason outside the PR under test, each with
# the task that owns the fix. They still run and print, but they cannot fail
# this script. If one starts passing, this script fails, so its entry is
# removed rather than left to hide a later regression. An entry naming a
# suite that no longer exists fails it too: system_3 #10808 deleted
# lake_client_publish_unit.sh while its entry stayed behind, and nothing
# noticed.
declare -A KNOWN_FAILING=()

self="$(basename "${BASH_SOURCE[0]}")"
passed=()
failed=()
known_failed=()
stale_known=()

for name in "${!KNOWN_FAILING[@]}"; do
  if [ ! -f "tests/$name" ]; then
    echo "=== $name: listed as known-failing, but no such suite exists; remove its entry"
    stale_known+=("$name")
  fi
done

for f in tests/*_unit.sh; do
  name="$(basename "$f")"
  [ "$name" = "$self" ] && continue
  echo
  echo "=== $name"
  start=$SECONDS
  if bash "$f"; then
    rc=0
  else
    rc=$?
  fi
  took=$((SECONDS - start))
  if [ -n "${KNOWN_FAILING[$name]:-}" ]; then
    if [ "$rc" -ne 0 ]; then
      echo "=== $name: rc=$rc (${took}s), known-failing: ${KNOWN_FAILING[$name]}"
      known_failed+=("$name")
    else
      echo "=== $name: passed (${took}s), but it is listed as known-failing; remove its entry"
      stale_known+=("$name")
    fi
  elif [ "$rc" -eq 0 ]; then
    echo "=== $name: passed (${took}s)"
    passed+=("$name")
  else
    echo "=== $name: FAILED rc=$rc (${took}s)"
    failed+=("$name")
  fi
done

echo
echo "run_unit: ${#passed[@]} passed, ${#failed[@]} failed, ${#known_failed[@]} known-failing, ${#stale_known[@]} stale known-failing entries"
for n in "${failed[@]}"; do echo "  FAILED: $n"; done
for n in "${known_failed[@]}"; do echo "  known-failing: $n (${KNOWN_FAILING[$n]})"; done
for n in "${stale_known[@]}"; do echo "  stale known-failing entry (passes, or no such suite): $n"; done

# A run with no suite at all is not a pass.
if [ "${#passed[@]}" -eq 0 ]; then
  echo "run_unit: no suite passed; refusing to report green" >&2
  exit 1
fi
[ "${#failed[@]}" -eq 0 ] && [ "${#stale_known[@]}" -eq 0 ]
