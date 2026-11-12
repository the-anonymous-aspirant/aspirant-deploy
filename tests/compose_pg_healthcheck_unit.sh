#!/usr/bin/env bash
set -euo pipefail

# Every Postgres service whose healthcheck runs pg_isready has an init and an
# exec-form check (system_3 #10684, mirroring #10677). With the postmaster as
# PID 1 and a CMD-SHELL probe, a probe that overruns its timeout leaves
# pg_isready orphaned; the postmaster adopts it and, when it exits 2, treats it
# as a crashed backend: every connection dropped, crash recovery. That reset the
# system_3 database for ~7 s on 2026-11-12. `init: true` reaps the orphan; the
# exec form spawns no shell to be killed out from under it. Checking every
# committed docker-compose*.yml keeps a new Postgres service honest.
#
# Usage: ./tests/compose_pg_healthcheck_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

# check_file <path>: prints one "<service> <verdict>" line per pg_isready
# service and exits non-zero when any lacks init or uses a shell-form check.
# A file with no pg_isready service prints nothing and passes.
check_file() {
  python3 - "$1" <<'EOF'
import sys
import yaml

services = (yaml.safe_load(open(sys.argv[1])) or {}).get("services") or {}
bad = 0
for name, spec in services.items():
    test = ((spec or {}).get("healthcheck") or {}).get("test")
    words = test if isinstance(test, list) else [str(test or "")]
    if not any("pg_isready" in str(w) for w in words):
        continue
    exec_form = isinstance(test, list) and test[:2] == ["CMD", "pg_isready"]
    init = (spec or {}).get("init") is True
    verdict = "ok" if exec_form and init else f"BAD(exec_form={exec_form},init={init})"
    print(f"{name} {verdict}")
    bad += verdict != "ok"
sys.exit(1 if bad else 0)
EOF
}

record() {
  local ok="$1" label="$2"
  if [[ "$ok" == "yes" ]]; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %s\n" "$label"
  fi
}

# Negative controls: the shell form, and a missing init, must each be refused.
cat > "$TMPDIR_TEST/shell_form.yml" <<'EOF'
services:
  db:
    init: true
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U x"]
EOF
cat > "$TMPDIR_TEST/no_init.yml" <<'EOF'
services:
  db:
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "x"]
EOF
for bad in shell_form no_init; do
  if check_file "$TMPDIR_TEST/$bad.yml" >/dev/null; then
    record no "negative control: $bad is refused"
  else
    record yes "negative control: $bad is refused"
  fi
done

# Positive control: the check sees the services it is meant to. These three
# are the containers #10684 names; a rename must update this list, not
# silently shrink the check to nothing.
seen="$(for f in docker-compose*.yml; do check_file "$f" || true; done | awk '{print $1}' | sort | tr '\n' ' ')"
for want in postgres penpot-postgres catalog; do
  if [[ " $seen" == *" $want "* ]]; then
    record yes "positive control: $want is checked"
  else
    record no "positive control: $want is checked (seen: $seen)"
  fi
done

for f in docker-compose*.yml; do
  if out="$(check_file "$f")"; then
    record yes "$f: every pg_isready service has init and an exec-form check"
  else
    record no "$f: every pg_isready service has init and an exec-form check"
    printf '%s\n' "$out" | grep -v ' ok$' | sed 's/^/        /'
  fi
done

echo
echo "compose_pg_healthcheck_unit: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
