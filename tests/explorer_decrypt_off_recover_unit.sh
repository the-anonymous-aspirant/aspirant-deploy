#!/usr/bin/env bash
#
# scripts/explorer-decrypt-off-recover.sh (system_3 #12207, under #12203;
# security c75726 on #12202, option (a)).
#
# The script brings an exited decrypt-on explorer-api back with decrypt off.
# Security's five conditions, each with cases here and a negative control
# where dropping it would otherwise go unnoticed:
#   1. it acts only on the decrypt-on container: exited, policy `no`, label on;
#   2. the recreate carries none of the key's variables, and no key is read;
#   3. it takes the verb's lock and does nothing while it is held;
#   4. each recovery writes one line, `<UTC time> exit=<code>`, and nothing
#      else, before the recreate;
#   5. a reboot (no key file, an empty runtime dir) is recovered.
#
# No real container runs. A fake `docker`, first on PATH, answers
# `compose ps` and `inspect` from the case's variables and records each call:
# its argv, working directory, the key variables in its environment, whether
# the lock is held, and how many lines the log holds at that moment.
#
# Usage: ./tests/explorer_decrypt_off_recover_unit.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

SCRIPT=./scripts/explorer-decrypt-off-recover.sh
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FAKE_BIN="$TMPDIR_TEST/bin"
DEPLOY_DIR="$TMPDIR_TEST/deploy"
mkdir -p "$FAKE_BIN" "$DEPLOY_DIR"

cat > "$FAKE_BIN/docker" <<'SHIM'
#!/usr/bin/env bash
# FAKE_DOWN=1: dockerd is not up (boot). FAKE_CIDS: what `compose ps -q`
# prints. FAKE_STATE_<cid>: what `inspect` prints for it. FAKE_UP_RC: the
# recreate's exit code.
{
  echo "ARGV: $*"
  echo "CWD: $PWD"
  for v in EXPLORER_API_RESTART LAKE_KEK_FILE_HOST LAKE_KEK_FINGERPRINT LAKE_KEK_HEX LAKE_KEK_FILE; do
    echo "$v: ${!v:-}"
  done
  if flock -n "$FAKE_LOCK" true; then echo "LOCK: free"; else echo "LOCK: held"; fi
  echo "LOGLINES: $(cat "$FAKE_LOG" 2>/dev/null | wc -l)"
  echo "END"
} >> "$FAKE_CALLS"
if [ "${FAKE_DOWN:-0}" = 1 ]; then
  echo "Cannot connect to the Docker daemon" >&2
  exit 1
fi
case "$*" in
  "compose --profile explorer ps -a -q explorer-api")
    [ -n "${FAKE_CIDS:-}" ] && printf '%s\n' $FAKE_CIDS
    exit 0 ;;
  "inspect --format "*)
    cid="${*: -1}"
    var="FAKE_STATE_$cid"
    printf '%s\n' "${!var:-}"
    exit 0 ;;
  "compose --profile explorer up -d --wait --wait-timeout 180 --force-recreate --no-deps explorer-api")
    exit "${FAKE_UP_RC:-0}" ;;
esac
exit 0
SHIM
chmod +x "$FAKE_BIN/docker"

HEX="feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"
CALLS="$TMPDIR_TEST/calls.log"
OUT="$TMPDIR_TEST/out.log"
LINE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z exit=[0-9]+$'

PASS=0
FAIL=0
check() {
  local label="$1" ok="$2"
  if [ "$ok" = yes ]; then
    PASS=$((PASS + 1)); echo "[PASS] $label"
  else
    FAIL=$((FAIL + 1)); echo "[FAIL] $label"
  fi
}

# run_case <script> [VAR=value ...]: one tick in a fresh runtime and state
# dir, with the caller's key variables all set, as the worst case. Sets RC,
# RUNTIME, LOG.
run_case() {
  local script="$1"
  shift
  RUNTIME="$(mktemp -d -p "$TMPDIR_TEST" run.XXXXXX)"
  local state_home="$TMPDIR_TEST/state.$RANDOM$RANDOM"
  LOG="$state_home/aspirant/explorer-decrypt-off.log"
  : > "$CALLS"
  RC=0
  env XDG_RUNTIME_DIR="$RUNTIME" XDG_STATE_HOME="$state_home" \
    ASPIRANT_DEPLOY_DIR="$DEPLOY_DIR" \
    FAKE_CALLS="$CALLS" FAKE_LOCK="$RUNTIME/explorer-api-decrypt.lock" FAKE_LOG="$LOG" \
    FAKE_CIDS=c1 \
    EXPLORER_API_RESTART=no LAKE_KEK_FILE_HOST=/dev/shm/lake_kek.x \
    LAKE_KEK_FINGERPRINT=0123456789abcdef LAKE_KEK_HEX="$HEX" LAKE_KEK_FILE=/dev/fd/3 \
    PATH="$FAKE_BIN:$PATH" \
    "$@" bash "$script" >"$OUT" 2>&1 || RC=$?
}
up_calls() { grep -c '^ARGV: compose --profile explorer up ' "$CALLS" || true; }
log_lines() { cat "$LOG" 2>/dev/null | wc -l; }
# up_block: the fake docker's record of the recreate call.
up_block() { awk '/^ARGV: compose --profile explorer up /{c=1} c{print} /^END$/{c=0}' "$CALLS"; }
env_clean() {
  local b
  b="$(up_block)"
  for v in EXPLORER_API_RESTART LAKE_KEK_FILE_HOST LAKE_KEK_FINGERPRINT LAKE_KEK_HEX LAKE_KEK_FILE; do
    printf '%s\n' "$b" | grep -qx "$v: " || return 1
  done
}

# --- condition 1: the decrypt-on container, and only it ----------------------

run_case "$SCRIPT" FAKE_STATE_c1='exited|3|no|on'
check "exited + no + on: recovered (exit 0)" "$([ "$RC" = 0 ] && echo yes || echo no)"
check "exited + no + on: one recreate" "$([ "$(up_calls)" = 1 ] && echo yes || echo no)"
check "the recreate runs from the deploy checkout" "$(grep -qxF "CWD: $DEPLOY_DIR" "$CALLS" && echo yes || echo no)"
check "it reads the container through inspect's four fields, not its environment" \
  "$(grep -qF 'ARGV: inspect --format {{.State.Status}}|{{.State.ExitCode}}|{{.HostConfig.RestartPolicy.Name}}|{{index .Config.Labels "aspirant.explorer.decrypt"}} c1' "$CALLS" && echo yes || echo no)"

for state in 'exited|3|unless-stopped|' 'running|0|no|on' 'exited|0|no|' 'exited|0|unless-stopped|on' 'created|0|no|on' 'restarting|1|no|on'; do
  run_case "$SCRIPT" FAKE_STATE_c1="$state"
  check "left alone: $state (exit 0, no recreate, no line)" \
    "$([ "$RC" = 0 ] && [ "$(up_calls)" = 0 ] && [ "$(log_lines)" = 0 ] && echo yes || echo no)"
done
run_case "$SCRIPT" FAKE_CIDS=""
check "no explorer-api container: nothing to do (exit 0, no recreate)" \
  "$([ "$RC" = 0 ] && [ "$(up_calls)" = 0 ] && echo yes || echo no)"
run_case "$SCRIPT" FAKE_CIDS="c1 c2" FAKE_STATE_c1='running|0|unless-stopped|' FAKE_STATE_c2='exited|137|no|on'
check "two containers, the second decrypt-on and exited: recovered, its exit code logged" \
  "$([ "$(up_calls)" = 1 ] && grep -qx '.* exit=137' "$LOG" && echo yes || echo no)"

# Negative controls: a copy without the label test, or without the policy
# test, acts on a container it must leave.
NO_LABEL="$TMPDIR_TEST/recover-no-label.sh"
sed 's/ && \[ "\$decrypt" = on \]//' "$SCRIPT" > "$NO_LABEL"
if diff -q "$SCRIPT" "$NO_LABEL" >/dev/null; then
  check "negative control: the label-test cut matched something" no
else
  run_case "$NO_LABEL" FAKE_STATE_c1='exited|0|no|'
  check "negative control: a copy without the label test is caught (it recreates a no-label container)" \
    "$([ "$(up_calls)" = 1 ] && echo yes || echo no)"
fi
NO_POLICY="$TMPDIR_TEST/recover-no-policy.sh"
sed 's/ && \[ "\$policy" = no \]//' "$SCRIPT" > "$NO_POLICY"
if diff -q "$SCRIPT" "$NO_POLICY" >/dev/null; then
  check "negative control: the policy-test cut matched something" no
else
  run_case "$NO_POLICY" FAKE_STATE_c1='exited|0|unless-stopped|on'
  check "negative control: a copy without the policy test is caught (it recreates an unless-stopped container)" \
    "$([ "$(up_calls)" = 1 ] && echo yes || echo no)"
fi

# --- condition 2: no key, and the recreate carries none of its variables -----

run_case "$SCRIPT" FAKE_STATE_c1='exited|3|no|on'
check "the recreate's environment has none of the five key and restart variables, though the caller set all" \
  "$(env_clean && echo yes || echo no)"
check "no key text in the output" "$(! grep -qF "$HEX" "$OUT" && echo yes || echo no)"
check "no key text in the log" "$(! grep -qF "$HEX" "$LOG" && echo yes || echo no)"
check "it never calls docker logs" "$(! grep -q '^ARGV: logs' "$CALLS" && echo yes || echo no)"
# Code lines only: the header names docker.sock to say it is never used.
check "its code never reads .Config.Env, never names docker.sock, never touches a key file" \
  "$(! grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -qE 'Config\.Env|docker\.sock|lake_kek\.|LAKE_KEK_HEX"?\}|\$LAKE_KEK' && echo yes || echo no)"

NO_UNSET="$TMPDIR_TEST/recover-no-unset.sh"
sed 's/env -u EXPLORER_API_RESTART -u LAKE_KEK_FILE_HOST -u LAKE_KEK_FINGERPRINT /env /' "$SCRIPT" > "$NO_UNSET"
if diff -q "$SCRIPT" "$NO_UNSET" >/dev/null; then
  check "negative control: the env -u cut matched something" no
else
  run_case "$NO_UNSET" FAKE_STATE_c1='exited|3|no|on'
  check "negative control: a recreate without the env -u is caught (it sees the key's variables)" \
    "$(! env_clean && echo yes || echo no)"
fi

# --- condition 3: the verb's lock --------------------------------------------

run_case "$SCRIPT" FAKE_STATE_c1='exited|3|no|on'
check "the recreate runs under the lock" "$(up_block | grep -qx 'LOCK: held' && echo yes || echo no)"

# run_locked <script>: one tick while this shell holds the lock.
run_locked() {
  local script="$1"
  local held_runtime
  held_runtime="$(mktemp -d -p "$TMPDIR_TEST" held.XXXXXX)"
  exec 8>"$held_runtime/explorer-api-decrypt.lock"
  flock -n 8
  run_case "$script" FAKE_STATE_c1='exited|3|no|on' XDG_RUNTIME_DIR="$held_runtime" \
    FAKE_LOCK="$held_runtime/explorer-api-decrypt.lock"
  flock -u 8
  exec 8>&-
}
run_locked "$SCRIPT"
check "lock held (the verb is running): exit 0 and no docker call at all" \
  "$([ "$RC" = 0 ] && [ ! -s "$CALLS" ] && echo yes || echo no)"
NO_FLOCK="$TMPDIR_TEST/recover-no-flock.sh"
sed 's/^flock -n 9 || exit 0$/true/' "$SCRIPT" > "$NO_FLOCK"
if diff -q "$SCRIPT" "$NO_FLOCK" >/dev/null; then
  check "negative control: the flock cut matched something" no
else
  run_locked "$NO_FLOCK"
  check "negative control: a copy without the flock is caught (it recreates under a held lock)" \
    "$([ "$(up_calls)" = 1 ] && echo yes || echo no)"
fi

# The verb and this script must lock the same file.
verb_lock="$(sed -n 's/^ *lock_file="\(.*\)"$/\1/p' scripts/lake-skeleton.sh)"
unit_lock="$(sed -n 's/^LOCK_FILE="\(.*\)"$/\1/p' "$SCRIPT")"
check "the verb and the recovery lock the same path ($unit_lock)" \
  "$([ -n "$verb_lock" ] && [ "$verb_lock" = "$unit_lock" ] && echo yes || echo no)"

# --- condition 4: one line per recovery, and nothing else --------------------

run_case "$SCRIPT" FAKE_STATE_c1='exited|3|no|on'
check "one recovery: exactly one log line" "$([ "$(log_lines)" = 1 ] && echo yes || echo no)"
check "the line is '<UTC time> exit=<code>' and nothing else" "$(grep -qE "$LINE_RE" "$LOG" && echo yes || echo no)"
check "the line carries the container's exit code" "$(grep -qx '.* exit=3' "$LOG" && echo yes || echo no)"
check "the line is written before the recreate" "$(up_block | grep -qx 'LOGLINES: 1' && echo yes || echo no)"
check "nothing else is printed by the script itself" "$([ ! -s "$OUT" ] && echo yes || echo no)"

run_case "$SCRIPT" FAKE_STATE_c1='exited|3|no|on' FAKE_UP_RC=1
check "a recreate that does not come back healthy: non-zero, its line still written" \
  "$([ "$RC" != 0 ] && [ "$(log_lines)" = 1 ] && echo yes || echo no)"

BLOCKED_STATE="$TMPDIR_TEST/not-a-dir"
: > "$BLOCKED_STATE"
run_case "$SCRIPT" FAKE_STATE_c1='exited|3|no|on' XDG_STATE_HOME="$BLOCKED_STATE"
check "a log that cannot be written: non-zero, and no recreate (decrypt never goes off unrecorded)" \
  "$([ "$RC" != 0 ] && [ "$(up_calls)" = 0 ] && echo yes || echo no)"

NO_LINE="$TMPDIR_TEST/recover-no-line.sh"
sed '/^printf .%s exit=%s/d' "$SCRIPT" > "$NO_LINE"
if diff -q "$SCRIPT" "$NO_LINE" >/dev/null; then
  check "negative control: the log-line cut matched something" no
else
  run_case "$NO_LINE" FAKE_STATE_c1='exited|3|no|on'
  check "negative control: a copy that writes no line is caught" "$([ "$(log_lines)" != 1 ] && echo yes || echo no)"
fi

# --- condition 5: a reboot -----------------------------------------------------

# After a reboot: a fresh, empty runtime dir (no key file, no lock), and the
# `no` container left exited by dockerd, here with the 0 a clean shutdown
# leaves.
run_case "$SCRIPT" FAKE_STATE_c1='exited|0|no|on'
check "reboot: the runtime dir holds no key file" "$([ -z "$(find "$RUNTIME" -name 'lake_kek.*')" ] && echo yes || echo no)"
check "reboot: recovered with decrypt off, one line, exit=0" \
  "$([ "$RC" = 0 ] && [ "$(up_calls)" = 1 ] && grep -qx '.* exit=0' "$LOG" && echo yes || echo no)"

run_case "$SCRIPT" FAKE_STATE_c1='exited|0|no|on' FAKE_DOWN=1
check "a tick before dockerd is up: non-zero, no line, no recreate (the next tick retries)" \
  "$([ "$RC" != 0 ] && [ "$(log_lines)" = 0 ] && [ "$(up_calls)" = 0 ] && echo yes || echo no)"

run_case "$SCRIPT" FAKE_STATE_c1='exited|0|no|on' XDG_RUNTIME_DIR="$TMPDIR_TEST/no-such-runtime"
check "a tick before the runtime dir exists: non-zero, and no docker call" \
  "$([ "$RC" != 0 ] && [ ! -s "$CALLS" ] && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
