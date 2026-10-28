#!/usr/bin/env bash
set -euo pipefail

# Every service in every committed docker-compose*.yml caps its json-file log
# (system_3 #9073). The cell has no /etc/docker/daemon.json, so a service with
# no `logging:` block writes an unrotated log that grows until the container is
# recreated. #5244 capped docker-compose.yml only; the lake skeleton then ran
# uncapped. Checking every file and every service keeps a new one honest.
#
# Usage: ./tests/compose_logging_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

# check_file <path>: prints one "<service> <verdict>" line per service and
# exits non-zero when the file has no services or any service is uncapped.
check_file() {
  python3 - "$1" <<'EOF'
import sys
import yaml

UNITS = {"k": 1024, "m": 1024**2, "g": 1024**3}
services = (yaml.safe_load(open(sys.argv[1])) or {}).get("services") or {}
if not services:
    print("<none> no-services")
    sys.exit(1)
bad = 0
for name, spec in services.items():
    log = (spec or {}).get("logging") or {}
    opts = log.get("options") or {}
    try:
        size = str(opts["max-size"])
        total = int(size[:-1]) * UNITS[size[-1].lower()] * int(str(opts["max-file"]))
        ok = log.get("driver") == "json-file" and 0 < total <= 100 * 1024**2
    except (KeyError, ValueError):
        ok = False
    print(f"{name} {'capped' if ok else 'UNCAPPED'}")
    bad += not ok
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

# Negative control: a service with no logging block must be refused.
cat > "$TMPDIR_TEST/uncapped.yml" <<'EOF'
services:
  app:
    image: busybox
EOF
if check_file "$TMPDIR_TEST/uncapped.yml" > "$TMPDIR_TEST/out" 2>&1; then
  record no "checker refuses an uncapped service"
else
  record yes "checker refuses an uncapped service"
fi

# Every committed compose file.
mapfile -t files < <(git ls-files 'docker-compose*.yml')
[[ ${#files[@]} -ge 3 ]] && record yes "found ${#files[@]} compose files" || record no "found ${#files[@]} compose files (expected >= 3)"
for f in "${files[@]}"; do
  if check_file "$f" > "$TMPDIR_TEST/out" 2>&1; then
    record yes "$f: all $(wc -l < "$TMPDIR_TEST/out") services capped"
  else
    record no "$f: $(grep -v ' capped$' "$TMPDIR_TEST/out" | tr '\n' ' ')"
  fi
done

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
