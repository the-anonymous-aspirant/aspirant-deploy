#!/usr/bin/env bash
#
# Test surface for scripts/gmail/gmail.sh's KEK handling (system_3 #10354):
# a real KEK must never reach `docker run` via `-e`, must land in a 0600
# tmpfs file bind-mounted read-only instead, and that file must be gone once
# gmail.sh exits, on both a successful and a failing run. Host bash, a fake
# `docker` on PATH, no real containers, no network. Every "KEK" here is a
# synthetic string; nothing is encrypted and nothing is persisted for real.
#
# Usage: ./tests/gmail_sh_unit.sh
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

WRAPPER="$PWD/scripts/gmail/gmail.sh"
fails=0
pass() { echo "  [PASS] $1"; }
fail() { echo "  [FAIL] $1${2:+ — $2}"; fails=$((fails + 1)); }

T="$(mktemp -d)"
# Real tmpfs, not $T (mktemp's backing filesystem on this host is ext2/ext3,
# not tmpfs) — gmail.sh now refuses a non-tmpfs runtime dir (#10492), and
# /run/user/<uid> on a real deploy always is tmpfs, so the test has to
# mirror that rather than the arbitrary disk mktemp -d happens to use.
TMPFS_RUNTIME="$(mktemp -d -p /dev/shm gmail-sh-unit-runtime.XXXXXX)"
trap 'rm -rf "$T" "$TMPFS_RUNTIME"' EXIT

mkdir -p "$T/bin" "$T/secrets"
echo '{"fake":"oauth-client"}' > "$T/secrets/gmail-oauth-client.json"

# A fake `docker`: `image inspect` always succeeds (so gmail.sh never tries a
# real build); `run` records its full argv, what arrived on its stdin when it
# was given `-i`, and what was in the runtime dir while it ran, then exits
# $STUB_RUN_RC.
cat > "$T/bin/docker" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "image" && "$2" == "inspect" ]]; then
  exit 0
fi
if [[ "$1" == "run" ]]; then
  printf '%s\n' "$*" > "$STUB_LOG.argv"
  ls -A "$XDG_RUNTIME_DIR" > "$STUB_LOG.runtime_ls"
  for a in "$@"; do
    if [[ "$a" == "-i" ]]; then cat > "$STUB_LOG.stdin"; break; fi
  done
  exit "${STUB_RUN_RC:-0}"
fi
echo "stub docker: unhandled subcommand: $*" >&2
exit 1
STUBEOF
chmod +x "$T/bin/docker"

FAKE_KEK="feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"

# run_wrapper NAME MODE — echoes the wrapper's exit code. MODE is `env` (the
# one-shot LAKE_KEK_HEX export), `fd` (LAKE_KEK_FILE=/dev/fd/3 fed by a
# here-string, as gmail_pull_and_ingest.sh does) or `none`.
run_wrapper() {
  local name="$1" mode="$2"
  rm -f "$T/$name".*
  set +e
  local base=(env -u LAKE_KEK_HEX -u LAKE_KEK_FILE PATH="$T/bin:$PATH" XDG_RUNTIME_DIR="${RUNTIME:-$TMPFS_RUNTIME}"
              GMAIL_SECRETS_DIR="$T/secrets" STUB_LOG="$T/$name" STUB_RUN_RC="${STUB_RUN_RC:-0}" LAKE_KEK_FINGERPRINT="nonsecretfp")
  case "$mode" in
    env)  "${base[@]}" LAKE_KEK_HEX="$FAKE_KEK" "$WRAPPER" status >"$T/$name.stdout" 2>"$T/$name.stderr" </dev/null ;;
    fd)   "${base[@]}" LAKE_KEK_FILE=/dev/fd/3 "$WRAPPER" status >"$T/$name.stdout" 2>"$T/$name.stderr" </dev/null 3<<<"$FAKE_KEK" ;;
    none) "${base[@]}" "$WRAPPER" status >"$T/$name.stdout" 2>"$T/$name.stderr" </dev/null ;;
  esac
  local rc=$?
  set -e
  echo "$rc"
}

# --- the key reaches the container on stdin, from either source -------------
for mode in env fd; do
  rc="$(STUB_RUN_RC=0 run_wrapper "ok-$mode" "$mode")"
  [[ "$rc" == "0" ]] && pass "$mode: wrapper exits 0 when the stub docker run succeeds" || fail "$mode: exit code on success" "got $rc"
  if grep -q "LAKE_KEK_HEX" "$T/ok-$mode.argv" 2>/dev/null || grep -qF "$FAKE_KEK" "$T/ok-$mode.argv" 2>/dev/null; then
    fail "$mode: neither LAKE_KEK_HEX nor the hex reaches docker run argv" "argv: $(cat "$T/ok-$mode.argv")"
  else
    pass "$mode: neither LAKE_KEK_HEX nor the hex reaches docker run argv"
  fi
  if grep -q -- "-i -e LAKE_KEK_FILE=/dev/stdin" "$T/ok-$mode.argv" 2>/dev/null; then
    pass "$mode: the container reads the key from stdin (-i, LAKE_KEK_FILE=/dev/stdin)"
  else
    fail "$mode: -i and LAKE_KEK_FILE=/dev/stdin" "argv: $(cat "$T/ok-$mode.argv" 2>/dev/null)"
  fi
  if [[ "$(cat "$T/ok-$mode.stdin" 2>/dev/null)" == "$FAKE_KEK" ]]; then
    pass "$mode: the container's stdin carried the key"
  else
    fail "$mode: the container's stdin carried the key"
  fi
  if [[ ! -s "$T/ok-$mode.runtime_ls" ]]; then
    pass "$mode: no key file sits in the runtime dir while the container runs (security c70261, #11344)"
  else
    fail "$mode: the runtime dir held a file during the run" "$(cat "$T/ok-$mode.runtime_ls")"
  fi
done

# --- a failing run propagates its exit code ----------------------------------
rc="$(STUB_RUN_RC=7 run_wrapper fail env)"
[[ "$rc" == "7" ]] && pass "wrapper propagates the stub docker run's exit code" || fail "wrapper exit code on failure" "got $rc"

# --- no KEK at all: no stdin hand-off ---------------------------------------
rc="$(STUB_RUN_RC=0 run_wrapper nokek none)"
[[ "$rc" == "0" ]] && pass "wrapper still runs with no KEK supplied" || fail "wrapper runs with no KEK" "got $rc"
if grep -q -- "LAKE_KEK_FILE" "$T/nokek.argv" 2>/dev/null || [[ -e "$T/nokek.stdin" ]]; then
  fail "no key hand-off without a KEK" "argv: $(cat "$T/nokek.argv")"
else
  pass "no key hand-off without a KEK"
fi

# --- nothing is written to the runtime dir at all, so its filesystem no longer
#     matters: a non-tmpfs XDG_RUNTIME_DIR stays empty (it was refused when the
#     key was staged there as a file, #10492).
DISK_RUNTIME="$T/not-tmpfs-runtime"
mkdir -p "$DISK_RUNTIME"
rc="$(RUNTIME="$DISK_RUNTIME" STUB_RUN_RC=0 run_wrapper notmpfs env)"
[[ "$rc" == "0" && -z "$(ls -A "$DISK_RUNTIME")" ]] \
  && pass "a non-tmpfs runtime dir receives nothing" \
  || fail "a non-tmpfs runtime dir receives nothing" "rc=$rc ls=$(ls -A "$DISK_RUNTIME")"

echo
if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails failure(s)"
  exit 1
fi
echo "all gmail.sh KEK-handling checks passed"
