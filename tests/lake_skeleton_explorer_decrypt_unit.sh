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
  echo "RESTART: ${EXPLORER_API_RESTART:-}"
  # A new open of the lock file conflicts with the verb's flock, if it holds it.
  if flock -n "$XDG_RUNTIME_DIR/explorer-api-decrypt.lock" true; then
    echo "LOCK: free"
  else
    echo "LOCK: held"
  fi
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
  env -u LAKE_KEK_HEX -u LAKE_KEK_FINGERPRINT -u LAKE_KEK_FILE_HOST -u EXPLORER_API_RESTART \
    LAKE_SKELETON_ROOT="$TMPDIR_TEST/root" \
    XDG_RUNTIME_DIR="$RUNTIME_DIR" \
    ASPIRANT_DEPLOY_DIR="$DEPLOY_DIR" \
    DOCKER_FAKE_LOG="$LOG" \
    PATH="$FAKE_BIN:$PATH" \
    "$@" bash "$script" explorer-decrypt-up >"$OUT" 2>&1 || RC=$?
}
# Key files only: the verb's lock file (#12203) sits in the same runtime dir.
staged_files() { find "$RUNTIME_DIR" -mindepth 1 -name 'lake_kek.*' | wc -l; }

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
# #12203: the decrypt-on container is created with restart "no", under the lock.
check "the decrypt-on recreate sees EXPLORER_API_RESTART=no" "$(has "$LOG" "RESTART: no")"
check "the decrypt-on recreate runs under the lock" "$(has "$LOG" "LOCK: held")"
check "EXPLORER_API_RESTART is set on that call only, not left in the verb's environment" \
  "$(grep -q 'EXPLORER_API_RESTART=no docker compose' ./scripts/lake-skeleton.sh \
     && ! grep -qE 'export +EXPLORER_API_RESTART|^ *EXPLORER_API_RESTART=' ./scripts/lake-skeleton.sh \
     && echo yes || echo no)"

# --- a start that never becomes healthy: non-zero, file deleted, way back ----

run_verb ./scripts/lake-skeleton.sh LAKE_KEK_HEX="$HEX" LAKE_KEK_FINGERPRINT="$FPR" DOCKER_FAKE_RC=1
check "unhealthy start: exit 1" "$([ "$RC" = 1 ] && echo yes || echo no)"
check "unhealthy start: the staged file is deleted" "$([ "$(staged_files)" = 0 ] && echo yes || echo no)"
check "unhealthy start: names the decrypt-off way back" "$(has "$OUT" "up -d --force-recreate explorer-api")"

# --- a refused key: the verb recovers with decrypt off (#12202, c75726) -----

# call_block <n>: the fake docker's record of its n-th call.
call_block() { awk -v n="$1" '/^CALL: /{c=($2==n)} c' "$LOG"; }
# refused_key_checks <script> [VAR=value ...]: run the refused-key path; sets
# OK_ENV (the recovery saw neither key variable) and OK_RESTART (it saw no
# EXPLORER_API_RESTART, so the decrypt-off container is `unless-stopped`).
refused_key_checks() {
  local script="$1"
  shift
  run_verb "$script" LAKE_KEK_HEX="$HEX" LAKE_KEK_FINGERPRINT="$FPR" DOCKER_FAKE_RCS="1 0" "$@"
  second="$(call_block 2)"
  OK_ENV="$(printf '%s\n' "$second" | grep -qx 'FILE_HOST: ' && printf '%s\n' "$second" | grep -qx 'FINGERPRINT: ' && echo yes || echo no)"
  OK_RESTART="$(printf '%s\n' "$second" | grep -qx 'RESTART: ' && echo yes || echo no)"
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
check "refused key: the decrypt-on start had EXPLORER_API_RESTART=no" \
  "$(call_block 1 | grep -qx 'RESTART: no' && echo yes || echo no)"
check "refused key: the recovery has no EXPLORER_API_RESTART, so it is unless-stopped again" "$OK_RESTART"
check "refused key: the recovery runs under the verb's lock" \
  "$(printf '%s\n' "$second" | grep -qx 'LOCK: held' && echo yes || echo no)"

# A caller's shell that exports EXPLORER_API_RESTART=no must not reach the
# recovery: the decrypt-off container must restart on its own (#12203).
refused_key_checks ./scripts/lake-skeleton.sh EXPLORER_API_RESTART=no
check "refused key, EXPLORER_API_RESTART=no exported by the caller: the recovery still has none" "$OK_RESTART"
NO_UNSET_RESTART="$TMPDIR_TEST/lake-skeleton-no-unset-restart.sh"
sed 's/env -u EXPLORER_API_RESTART /env /' ./scripts/lake-skeleton.sh > "$NO_UNSET_RESTART"
if diff -q ./scripts/lake-skeleton.sh "$NO_UNSET_RESTART" >/dev/null; then
  check "negative control: the -u EXPLORER_API_RESTART cut matched something" no
else
  refused_key_checks "$NO_UNSET_RESTART" EXPLORER_API_RESTART=no
  check "negative control: a recovery without -u EXPLORER_API_RESTART is caught" \
    "$([ "$OK_RESTART" = no ] && echo yes || echo no)"
fi

# Negative control (c75726, condition 2): a recovery written without the
# `env -u` of the key variables inherits the refused key, and the env check
# above must catch it.
NO_UNSET="$TMPDIR_TEST/lake-skeleton-no-unset.sh"
sed 's/ -u LAKE_KEK_FILE_HOST -u LAKE_KEK_FINGERPRINT / /' ./scripts/lake-skeleton.sh > "$NO_UNSET"
if diff -q ./scripts/lake-skeleton.sh "$NO_UNSET" >/dev/null; then
  check "negative control: the env -u cut matched something" no
else
  refused_key_checks "$NO_UNSET"
  check "negative control: a recovery without env -u is caught (it sees the key's variables)" \
    "$([ "$OK_ENV" = no ] && echo yes || echo no)"
fi

# Negative control (#12203): a decrypt-on recreate without
# EXPLORER_API_RESTART=no keeps `unless-stopped`, and the check must see it.
NO_RESTART_NO="$TMPDIR_TEST/lake-skeleton-no-restart-no.sh"
sed 's/EXPLORER_API_RESTART=no docker compose/docker compose/' ./scripts/lake-skeleton.sh > "$NO_RESTART_NO"
if diff -q ./scripts/lake-skeleton.sh "$NO_RESTART_NO" >/dev/null; then
  check "negative control: the EXPLORER_API_RESTART=no cut matched something" no
else
  run_verb "$NO_RESTART_NO" LAKE_KEK_HEX="$HEX" LAKE_KEK_FINGERPRINT="$FPR"
  check "negative control: a decrypt-on recreate without EXPLORER_API_RESTART=no is caught" \
    "$(grep -qx 'RESTART: no' "$LOG" && echo no || echo yes)"
fi

# --- the lock: the verb refuses while the host-side unit holds it (#12203) ---

LOCK_PATH="$RUNTIME_DIR/explorer-api-decrypt.lock"
# run_verb_locked <script>: run the verb while this shell holds the lock.
run_verb_locked() {
  exec 9>"$LOCK_PATH"
  flock -n 9
  run_verb "$1" LAKE_KEK_HEX="$HEX" LAKE_KEK_FINGERPRINT="$FPR"
  flock -u 9
  exec 9>&-
}
run_verb_locked ./scripts/lake-skeleton.sh
check "lock held: refuses (exit 1)" "$([ "$RC" = 1 ] && echo yes || echo no)"
check "lock held: docker is never called" "$([ ! -s "$LOG" ] && echo yes || echo no)"
check "lock held: says the explorer is being brought back with decrypt off" "$(has "$OUT" "is held, so explorer-api is being brought back")"
check "lock held: the staged file is deleted on the refusal" "$([ "$(staged_files)" = 0 ] && echo yes || echo no)"
check "lock held: no key text in the output" "$(grep -qF "$HEX" "$OUT" && echo no || echo yes)"
check "the lock is on the runtime tmpfs, at the path the unit takes" "$([ -e "$LOCK_PATH" ] && echo yes || echo no)"

# Negative control: a verb without the flock runs while the lock is held.
NO_FLOCK="$TMPDIR_TEST/lake-skeleton-no-flock.sh"
sed 's/if ! flock -n 8; then/if false; then/' ./scripts/lake-skeleton.sh > "$NO_FLOCK"
if diff -q ./scripts/lake-skeleton.sh "$NO_FLOCK" >/dev/null; then
  check "negative control: the flock cut matched something" no
else
  run_verb_locked "$NO_FLOCK"
  check "negative control: a verb without the flock is caught (it calls docker under a held lock)" \
    "$([ -s "$LOG" ] && echo yes || echo no)"
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
# #12203: restart "no" only on the verb's say-so, and a label derived from the
# key mount's own variable.
if svc.get("restart") != "${EXPLORER_API_RESTART:-unless-stopped}":
    problems.append(f"restart is {svc.get('restart')!r}")
labels = svc.get("labels") or {}
if isinstance(labels, list):
    labels = dict(l.split("=", 1) if "=" in l else (l, "") for l in labels)
if labels.get("aspirant.explorer.decrypt") != "${LAKE_KEK_FILE_HOST:+on}":
    problems.append(f"label aspirant.explorer.decrypt is {labels.get('aspirant.explorer.decrypt')!r}")
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

# Negative control (#12203): a fixed `restart: unless-stopped` is caught.
BAD_RESTART="$TMPDIR_TEST/compose-bad-restart.yml"
python3 - docker-compose.yml "$BAD_RESTART" <<'EOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
d["services"]["explorer-api"]["restart"] = "unless-stopped"
yaml.safe_dump(d, open(sys.argv[2], "w"))
EOF
rc=0; static_check "$BAD_RESTART" >/dev/null 2>&1 || rc=$?
check "negative control: the static check fails a compose with a fixed restart policy" \
  "$([ "$rc" = 1 ] && echo yes || echo no)"

# --- the rendered config, through the real compose (#12203) ------------------
# What dockerd is given, not only the source text: with a key staged, restart
# "no" and the label `on`; without one, `unless-stopped` and an empty label,
# even when EXPLORER_API_RESTART=no leaks in alone (the unit then still leaves
# it, since it needs both). Needs `docker compose` on the host; a missing one
# fails the check rather than skipping it.
RENDER_DIR="$TMPDIR_TEST/render"
mkdir -p "$RENDER_DIR"
cp docker-compose.yml "$RENDER_DIR/"
: > "$RENDER_DIR/.env"
# render <VAR=value ...>: prints "<restart>|<label>|<mount source>".
render() {
  (cd "$RENDER_DIR" && env -i PATH="$PATH" HOME="$HOME" \
     DB_PASSWORD=x JWT_SECRET=x PENPOT_DB_PASSWORD=x PENPOT_SECRET_KEY=x "$@" \
     docker compose -f docker-compose.yml --profile explorer config --format json explorer-api 2>/dev/null) |
  python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]["explorer-api"]
src = [v.get("source") for v in s.get("volumes", []) if v.get("target") == "/run/secrets/lake_kek"]
print("%s|%s|%s" % (s.get("restart"), (s.get("labels") or {}).get("aspirant.explorer.decrypt"), src[0] if src else None))
' 2>/dev/null || echo "render failed"
}
KEYED="$(render LAKE_KEK_FILE_HOST=/dev/shm/lake_kek.test LAKE_KEK_FINGERPRINT="$FPR" EXPLORER_API_RESTART=no)"
PLAIN="$(render)"
STRAY="$(render EXPLORER_API_RESTART=no)"
check "rendered, key staged: restart no, label on, the key file mounted (got $KEYED)" \
  "$([ "$KEYED" = "no|on|/dev/shm/lake_kek.test" ] && echo yes || echo no)"
check "rendered, plain recreate: unless-stopped, empty label, /dev/null mounted (got $PLAIN)" \
  "$([ "$PLAIN" = "unless-stopped||/dev/null" ] && echo yes || echo no)"
check "rendered, EXPLORER_API_RESTART=no without a key: the label stays empty (got $STRAY)" \
  "$([ "$STRAY" = "no||/dev/null" ] && echo yes || echo no)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
