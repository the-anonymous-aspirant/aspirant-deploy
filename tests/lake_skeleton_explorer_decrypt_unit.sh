#!/usr/bin/env bash
#
# `lake-skeleton.sh explorer-decrypt-up` and explorer-api's key wiring
# (system_3 #10777; security c64754 on #8814).
#
# The verb turns decrypt-on-read on for the deploy's explorer-api. The key must
# reach the container only as a 0600 tmpfs file mounted read-only and named by
# LAKE_KEK_FILE, never as LAKE_KEK_HEX in its environment: dockerd writes a
# container's environment to the unencrypted root disk.
#
# No real container starts. A fake `docker`, first on PATH, records for each
# `docker compose` call: its argv, its working directory, whether LAKE_KEK_HEX
# was still in its environment, and the staged file's path, mode and contents
# at that moment. The static half reads docker-compose.yml itself.
#
# Usage: ./tests/lake_skeleton_explorer_decrypt_unit.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
# The staging refuses a runtime dir that is not tmpfs (#10492), so the test
# stages under /dev/shm, as a deploy does under /run/user/<uid>.
RUNTIME_DIR="$(mktemp -d -p /dev/shm lake-explorer-decrypt-unit.XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST" "$RUNTIME_DIR"' EXIT

FAKE_BIN="$TMPDIR_TEST/bin"
DEPLOY_DIR="$TMPDIR_TEST/deploy"
mkdir -p "$FAKE_BIN" "$DEPLOY_DIR"

cat > "$FAKE_BIN/docker" <<'SHIM'
#!/usr/bin/env bash
# DOCKER_FAKE_RCS="1 0" gives each call in turn its own exit code.
n=$(( $(cat "$DOCKER_FAKE_LOG.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$DOCKER_FAKE_LOG.n"
{
  echo "CALL: $n"
  echo "STAGED: $(find "$XDG_RUNTIME_DIR" -name 'lake_kek.*' | wc -l)"
  echo "ARGV: $*"
  echo "CWD: $PWD"
  if [[ -n "${LAKE_KEK_HEX:-}" ]]; then echo "HEX: SET"; else echo "HEX: unset"; fi
  echo "FILE_HOST: ${LAKE_KEK_FILE_HOST:-}"
  echo "FINGERPRINT: ${LAKE_KEK_FINGERPRINT:-}"
  if [[ -n "${LAKE_KEK_FILE_HOST:-}" && -f "$LAKE_KEK_FILE_HOST" ]]; then
    echo "FILE_MODE: $(stat -c %a "$LAKE_KEK_FILE_HOST")"
    echo "FILE_BODY: $(cat "$LAKE_KEK_FILE_HOST")"
  else
    echo "FILE_MODE: missing"
  fi
} >> "$DOCKER_FAKE_LOG"
if [[ -n "${DOCKER_FAKE_RCS:-}" ]]; then
  rc="$(echo "$DOCKER_FAKE_RCS" | cut -d' ' -f"$n")"
  exit "${rc:-0}"
fi
exit "${DOCKER_FAKE_RC:-0}"
SHIM
chmod +x "$FAKE_BIN/docker"

HEX="feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"
FPR="0123456789abcdef"
LOG="$TMPDIR_TEST/docker.log"
OUT="$TMPDIR_TEST/out.log"

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
has() { grep -qF -- "$2" "$1" && echo yes || echo no; }

# run_verb <script> [VAR=value ...]: runs the verb with a fake docker; sets RC.
run_verb() {
  local script="$1"
  shift
  : > "$LOG"
  rm -f "$LOG.n"
  RC=0
  env -u LAKE_KEK_HEX -u LAKE_KEK_FINGERPRINT -u LAKE_KEK_FILE_HOST \
    LAKE_SKELETON_ROOT="$TMPDIR_TEST/root" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    ASPIRANT_DEPLOY_DIR="$DEPLOY_DIR" \
    DOCKER_FAKE_LOG="$LOG" \
    PATH="$FAKE_BIN:$PATH" \
    "$@" bash "$script" explorer-decrypt-up >"$OUT" 2>&1 || RC=$?
}
staged_files() { find "$RUNTIME_DIR" -mindepth 1 | wc -l; }

# --- refusals: no key, or a key without its fingerprint ----------------------

run_verb ./scripts/lake-skeleton.sh
check "no key: refuses (exit 1)" "$([ "$RC" = 1 ] && echo yes || echo no)"
check "no key: docker is never called" "$([ ! -s "$LOG" ] && echo yes || echo no)"
check "no key: says how to supply one without echoing it" "$(has "$OUT" "read -rs LAKE_KEK_HEX")"

run_verb ./scripts/lake-skeleton.sh LAKE_KEK_HEX="$HEX"
check "no fingerprint: refuses (exit 1)" "$([ "$RC" = 1 ] && echo yes || echo no)"
check "no fingerprint: docker is never called" "$([ ! -s "$LOG" ] && echo yes || echo no)"
check "no fingerprint: the staged file is deleted on the refusal" "$([ "$(staged_files)" = 0 ] && echo yes || echo no)"

# --- the path that brings it up ----------------------------------------------

run_verb ./scripts/lake-skeleton.sh LAKE_KEK_HEX="$HEX" LAKE_KEK_FINGERPRINT="$FPR"
check "with key and fingerprint: exit 0" "$([ "$RC" = 0 ] && echo yes || echo no)"
check "one docker call" "$([ "$(grep -c '^ARGV:' "$LOG")" = 1 ] && echo yes || echo no)"
check "the closing message says a restart leaves it stopped, and how to bring it back" \
  "$(has "$OUT" "A restart (a crash, a daemon restart, a reboot) leaves it stopped")"
check "it recreates explorer-api alone and waits for it to be healthy" \
  "$(has "$LOG" "ARGV: compose --profile explorer up -d --wait --wait-timeout 180 --force-recreate --no-deps explorer-api")"
check "it runs from the deploy checkout" "$(has "$LOG" "CWD: $DEPLOY_DIR")"
check "LAKE_KEK_HEX is not in docker's environment" "$(has "$LOG" "HEX: unset")"
check "the key is not in docker's argv" "$(grep '^ARGV:' "$LOG" | grep -qF "$HEX" && echo no || echo yes)"
check "the fingerprint reaches compose" "$(has "$LOG" "FINGERPRINT: $FPR")"
check "the staged file is on the runtime tmpfs" "$(has "$LOG" "FILE_HOST: $RUNTIME_DIR/lake_kek.")"
check "the staged file is 0600 while compose runs" "$(has "$LOG" "FILE_MODE: 600")"
check "the staged file holds the key while compose runs" "$(has "$LOG" "FILE_BODY: $HEX")"
check "the staged file is deleted after the verb" "$([ "$(staged_files)" = 0 ] && echo yes || echo no)"

# --- a start that never becomes healthy: non-zero, file deleted, way back ----

run_verb ./scripts/lake-skeleton.sh LAKE_KEK_HEX="$HEX" LAKE_KEK_FINGERPRINT="$FPR" DOCKER_FAKE_RC=1
check "unhealthy start: exit 1" "$([ "$RC" = 1 ] && echo yes || echo no)"
check "unhealthy start: the staged file is deleted" "$([ "$(staged_files)" = 0 ] && echo yes || echo no)"
check "unhealthy start: names the decrypt-off way back" "$(has "$OUT" "up -d --force-recreate explorer-api")"

# --- a refused key: the verb recovers with decrypt off (#12202, c75726) -----

# call_block <n>: the fake docker's record of its n-th call.
call_block() { awk -v n="$1" '/^CALL: /{c=($2==n)} c' "$LOG"; }
# refused_key_checks <script> <prefix>: run the refused-key path; sets OK_* flags.
refused_key_checks() {
  run_verb "$1" LAKE_KEK_HEX="$HEX" LAKE_KEK_FINGERPRINT="$FPR" DOCKER_FAKE_RCS="1 0"
  second="$(call_block 2)"
  OK_ENV="$(printf '%s\n' "$second" | grep -qx 'FILE_HOST: ' && printf '%s\n' "$second" | grep -qx 'FINGERPRINT: ' && echo yes || echo no)"
}
refused_key_checks ./scripts/lake-skeleton.sh
check "refused key: still exits 1, since decrypt-on failed" "$([ "$RC" = 1 ] && echo yes || echo no)"
check "refused key: two docker calls, the start and the recovery" "$([ "$(grep -c '^ARGV:' "$LOG")" = 2 ] && echo yes || echo no)"
check "refused key: the recovery sees neither LAKE_KEK_FILE_HOST nor LAKE_KEK_FINGERPRINT" "$OK_ENV"
check "refused key: the key file is deleted before the recovery runs" \
  "$(printf '%s\n' "$second" | grep -qx 'STAGED: 0' && echo yes || echo no)"
check "refused key: the recovery recreates explorer-api alone and waits" \
  "$(printf '%s\n' "$second" | grep -qxF 'ARGV: compose --profile explorer up -d --wait --wait-timeout 180 --force-recreate --no-deps explorer-api' && echo yes || echo no)"
check "refused key: the recovery runs from the deploy checkout" \
  "$(printf '%s\n' "$second" | grep -qxF "CWD: $DEPLOY_DIR" && echo yes || echo no)"
check "refused key: one line says it is back up with decrypt off" "$(has "$OUT" "explorer-api is back up with decrypt off.")"
check "refused key: no key text in the output" "$(grep -qF "$HEX" "$OUT" && echo no || echo yes)"
check "refused key: the staged file is deleted after the verb" "$([ "$(staged_files)" = 0 ] && echo yes || echo no)"

# Negative control (c75726, condition 2): a recovery written without the
# `env -u` inherits the refused key, and the env check above must catch it.
NO_UNSET="$TMPDIR_TEST/lake-skeleton-no-unset.sh"
sed 's/env -u LAKE_KEK_FILE_HOST -u LAKE_KEK_FINGERPRINT //' ./scripts/lake-skeleton.sh > "$NO_UNSET"
if diff -q ./scripts/lake-skeleton.sh "$NO_UNSET" >/dev/null; then
  check "negative control: the env -u cut matched something" no
else
  refused_key_checks "$NO_UNSET"
  check "negative control: a recovery without env -u is caught (it sees the key's variables)" \
    "$([ "$OK_ENV" = no ] && echo yes || echo no)"
fi

# --- negative control: a copy whose verb skips the staging must fail above ---

UNSTAGED="$TMPDIR_TEST/lake-skeleton-unstaged.sh"
sed '/^# Structural, not per-verb (#10492):/,/^fi$/d' ./scripts/lake-skeleton.sh > "$UNSTAGED"
if diff -q ./scripts/lake-skeleton.sh "$UNSTAGED" >/dev/null; then
  check "negative control: the staging-removal cut matched something" no
else
  run_verb "$UNSTAGED" LAKE_KEK_HEX="$HEX" LAKE_KEK_FINGERPRINT="$FPR"
  check "negative control: without the staging, the verb refuses rather than run with LAKE_KEK_HEX set" \
    "$([ "$RC" = 1 ] && [ ! -s "$LOG" ] && echo yes || echo no)"
fi

# --- docker-compose.yml: explorer-api carries the key only by its mount -------

static_check() {
  python3 - "$1" <<'EOF'
import sys, yaml
svc = yaml.safe_load(open(sys.argv[1]))["services"]["explorer-api"]
env = svc.get("environment") or {}
if isinstance(env, list):
    env = dict(e.split("=", 1) if "=" in e else (e, "") for e in env)
problems = []
if "LAKE_KEK_HEX" in env or any("LAKE_KEK_HEX" in str(v) for v in env.values()):
    problems.append("LAKE_KEK_HEX in environment")
want = {
    "LAKE_ENVELOPE_DECRYPT": "${LAKE_KEK_FILE_HOST:+1}",
    "LAKE_KEK_FILE": "${LAKE_KEK_FILE_HOST:+/run/secrets/lake_kek}",
}
for k, v in want.items():
    if env.get(k) != v:
        problems.append(f"{k} is {env.get(k)!r}, want {v!r}")
vols = svc.get("volumes") or []
want_mount = {
    "type": "bind",
    "source": "${LAKE_KEK_FILE_HOST:-/dev/null}",
    "target": "/run/secrets/lake_kek",
    "read_only": True,
    "bind": {"create_host_path": False},
}
# Long form only: the short form is a legacy bind, which re-creates a deleted
# key file's path as a root-owned directory on restart.
if want_mount not in vols:
    problems.append(f"no read-only, non-creating key mount {want_mount!r}; volumes are {vols!r}")
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
EOF
}

rc=0; static_check docker-compose.yml > "$TMPDIR_TEST/static.out" 2>&1 || rc=$?
check "compose: decrypt and LAKE_KEK_FILE only when a file is staged, key only by a read-only non-creating bind, no LAKE_KEK_HEX" \
  "$([ "$rc" = 0 ] && echo yes || echo no)"
[ "$rc" = 0 ] || sed 's/^/       /' "$TMPDIR_TEST/static.out"

# Negative control: the static check must catch LAKE_KEK_HEX on the service.
BAD="$TMPDIR_TEST/compose-bad.yml"
python3 - docker-compose.yml "$BAD" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
d["services"]["explorer-api"]["environment"]["LAKE_KEK_HEX"] = "${LAKE_KEK_HEX:-}"
yaml.safe_dump(d, open(sys.argv[2], "w"))
EOF
rc=0; static_check "$BAD" >/dev/null 2>&1 || rc=$?
check "negative control: the static check fails a compose that adds LAKE_KEK_HEX" \
  "$([ "$rc" = 1 ] && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
