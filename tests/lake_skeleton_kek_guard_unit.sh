#!/usr/bin/env bash
#
# Structural-guard test for scripts/lake-skeleton.sh (#10492).
#
# #10354 added `stage_real_kek`, which writes a real LAKE_KEK_HEX to a 0600
# tmpfs file and unsets the env var before `compose` ever interpolates it —
# but only `ingest` called it. `promote` and `verify-at-rest` still reached
# `compose` with the hex exported, which dockerd would persist under
# `/var/lib/docker` on this cell's unencrypted root LV. This test asserts
# the structural fix: every verb that can reach `compose --profile client
# run --rm duckdb` is staged first, except `seed` (#10354's deliberate,
# tests-and-skeleton-only exemption).
#
# No real docker/Garage is touched. A fake `docker` shim, placed earlier in
# PATH, intercepts every `docker compose ... run --rm duckdb ...`
# invocation (that is what the `compose()` function in lake-skeleton.sh
# execs) and records whether LAKE_KEK_HEX was still present in ITS OWN
# environment at that moment — exactly the daemon-level exposure the real
# bug was. Every other docker subcommand (build, etc.) is a silent no-op so
# the script's own control flow completes without a real container ever
# starting.
#
# Usage: ./tests/lake_skeleton_kek_guard_unit.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_BIN="$TMPDIR_TEST/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/docker" <<'SHIM'
#!/usr/bin/env bash
if [[ "$*" == *"run --rm duckdb"* ]]; then
  state="unset"
  [[ -n "${LAKE_KEK_HEX:-}" ]] && state="SET"
  echo "$state RUN: $*" >> "$DOCKER_FAKE_LOG"
fi
exit 0
SHIM
chmod +x "$FAKE_BIN/docker"

MANIFEST="$TMPDIR_TEST/manifest.json"
cat > "$MANIFEST" <<'EOF'
{"dataset_id": "guard-test", "source": "unit test", "records": [{"path": "x", "sensitivity": "normal"}]}
EOF

PASS=0
FAIL=0

# Runs $2.. of $1 (a lake-skeleton.sh, real or mutated) with a synthetic KEK
# exported and a fake docker on PATH, then prints the one captured RUN line
# (or nothing, if the verb never reached `compose ... run --rm duckdb`).
captured_run_line() {
  local script="$1" log="$TMPDIR_TEST/docker.log"
  shift
  : > "$log"
  LAKE_KEK_HEX="feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface" \
    LAKE_SKELETON_ROOT="$TMPDIR_TEST/root" \
    DOCKER_FAKE_LOG="$log" \
    PATH="$FAKE_BIN:$PATH" \
    bash "$script" "$@" >"$TMPDIR_TEST/last_out.log" 2>&1 || true
  grep ' RUN: ' "$log" || true
}

# --- the guard holds, against the real script --------------------------

assert_guarded() {
  local verb="$1" line
  shift
  line="$(captured_run_line ./scripts/lake-skeleton.sh "$verb" "$@")"
  if [ -z "$line" ]; then
    FAIL=$((FAIL + 1))
    echo "[FAIL] $verb: never reached 'compose ... run --rm duckdb' — the test caught nothing, which is not evidence of safety"
    return
  fi
  case "$line" in
    unset*)
      PASS=$((PASS + 1))
      echo "[PASS] $verb: LAKE_KEK_HEX is unset by the time compose reaches docker"
      ;;
    *)
      FAIL=$((FAIL + 1))
      echo "[FAIL] $verb: LAKE_KEK_HEX is still SET when compose reaches docker — leaks to dockerd's env"
      echo "       $line"
      ;;
  esac
}

assert_guarded ingest "$MANIFEST"
assert_guarded promote
assert_guarded verify
assert_guarded verify-at-rest

# --- seed is deliberately exempt (#10354): its synthetic KEK still reaches
#     compose's env interpolation unstaged, and that is the design, not a gap.

line="$(captured_run_line ./scripts/lake-skeleton.sh seed)"
if [ -z "$line" ]; then
  FAIL=$((FAIL + 1))
  echo "[FAIL] seed: never reached 'compose ... run --rm duckdb' — the test caught nothing"
elif [[ "$line" == SET* ]]; then
  PASS=$((PASS + 1))
  echo "[PASS] seed: LAKE_KEK_HEX is still SET at compose — the #10354 exemption is real, not accidentally fixed"
else
  FAIL=$((FAIL + 1))
  echo "[FAIL] seed: LAKE_KEK_HEX was unset — the deliberate synthetic-skeleton exemption regressed"
fi

# --- negative control: the same assertion against a copy with the
#     structural guard call removed must FAIL. If it doesn't, this test
#     isn't testing the guard at all.

UNGUARDED="$TMPDIR_TEST/lake-skeleton-unguarded.sh"
sed '/^# Structural, not per-verb (#10492):/,/^fi$/d' ./scripts/lake-skeleton.sh > "$UNGUARDED"
if diff -q ./scripts/lake-skeleton.sh "$UNGUARDED" >/dev/null; then
  FAIL=$((FAIL + 1))
  echo "[FAIL] negative control: the guard-removal sed matched nothing — this test would pass even if the guard vanished"
else
  line="$(captured_run_line "$UNGUARDED" promote)"
  if [[ "$line" == SET* ]]; then
    PASS=$((PASS + 1))
    echo "[PASS] negative control: with the structural guard removed, promote leaks LAKE_KEK_HEX to docker — this test does detect the bug it exists for"
  else
    FAIL=$((FAIL + 1))
    echo "[FAIL] negative control: promote did not leak even with the guard removed ('$line') — the sed cut must have removed the wrong thing"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
