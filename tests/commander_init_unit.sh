#!/usr/bin/env bash
set -euo pipefail

# Unit test: the commander service must run with `init: true`.
#
# Every /valuation-statement/generate?format=pdf request runs LibreOffice,
# whose gpgme init spawns detached gpgconf/gpg/gpgsm helpers. Those re-parent
# to PID 1 when soffice exits; a bare uvicorn PID 1 never reaps them, so each
# export leaks 5 zombies (task #6671: 70 zombies in 8 days of production).
# `init: true` puts docker-init (tini) at PID 1, which reaps them.
#
# Parses the YAML rather than grepping line shapes, so reordering keys or
# reformatting the block cannot silently pass a regressed file.
#
# Usage: ./tests/commander_init_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0
FAIL=0

check() {
  local label="$1" ok="$2"
  if [[ "$ok" == "yes" ]]; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    printf "  FAIL  %s\n" "$label"
  fi
}

result="$(python3 - <<'EOF'
import yaml

with open("docker-compose.yml") as f:
    doc = yaml.safe_load(f)

svc = doc.get("services", {}).get("commander")
if svc is None:
    print("no-commander")
elif svc.get("init") is True:
    print("init-true")
else:
    print(f"init-missing:{svc.get('init')!r}")
EOF
)"

check "commander service exists in docker-compose.yml" \
  "$([[ "$result" != "no-commander" ]] && echo yes || echo no)"
check "commander runs with init: true (zombie reaper at PID 1)" \
  "$([[ "$result" == "init-true" ]] && echo yes || echo no)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
exit "$((FAIL > 0 ? 1 : 0))"
