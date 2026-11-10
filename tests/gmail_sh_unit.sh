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
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin" "$T/secrets" "$T/runtime"
echo '{"fake":"oauth-client"}' > "$T/secrets/gmail-oauth-client.json"

# A fake `docker`: `image inspect` always succeeds (so gmail.sh never tries a
# real build), `run` records its full argv and the KEK file's permission
# bits + content (read before the wrapper's own trap can delete it) to
# $STUB_LOG, then exits $STUB_RUN_RC.
cat > "$T/bin/docker" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "$1" == "image" && "$2" == "inspect" ]]; then
  exit 0
fi
if [[ "$1" == "run" ]]; then
  printf '%s\n' "$*" > "$STUB_LOG.argv"
  : > "$STUB_LOG.kekfile_path"
  for ((i = 1; i <= $#; i++)); do
    arg="${!i}"
    if [[ "$arg" == *:/run/secrets/lake_kek:ro ]]; then
      src="${arg%%:/run/secrets/lake_kek:ro}"
      if [[ -f "$src" ]]; then
        stat -c '%a' "$src" > "$STUB_LOG.kekfile_mode"
        cat "$src" > "$STUB_LOG.kekfile_content"
      fi
      printf '%s\n' "$src" > "$STUB_LOG.kekfile_path"
    fi
  done
  exit "${STUB_RUN_RC:-0}"
fi
echo "stub docker: unhandled subcommand: $*" >&2
exit 1
STUBEOF
chmod +x "$T/bin/docker"

FAKE_KEK="feedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedfacefeedface"

# run_wrapper NAME [LAKE_KEK_HEX_VALUE] — echoes the wrapper's exit code.
# LAKE_KEK_HEX_VALUE unset/empty means "do not export it at all".
run_wrapper() {
  local name="$1" kek="${2:-}"
  rm -f "$T/$name".*
  set +e
  if [[ -n "$kek" ]]; then
    PATH="$T/bin:$PATH" \
      XDG_RUNTIME_DIR="$T/runtime" \
      GMAIL_SECRETS_DIR="$T/secrets" \
      STUB_LOG="$T/$name" \
      STUB_RUN_RC="${STUB_RUN_RC:-0}" \
      LAKE_KEK_HEX="$kek" \
      LAKE_KEK_FINGERPRINT="nonsecretfp" \
      "$WRAPPER" status >"$T/$name.stdout" 2>"$T/$name.stderr"
  else
    PATH="$T/bin:$PATH" \
      XDG_RUNTIME_DIR="$T/runtime" \
      GMAIL_SECRETS_DIR="$T/secrets" \
      STUB_LOG="$T/$name" \
      STUB_RUN_RC="${STUB_RUN_RC:-0}" \
      env -u LAKE_KEK_HEX "$WRAPPER" status >"$T/$name.stdout" 2>"$T/$name.stderr"
  fi
  local rc=$?
  set -e
  echo "$rc"
}

# --- a successful run -------------------------------------------------------
rc="$(STUB_RUN_RC=0 run_wrapper ok "$FAKE_KEK")"
if [[ "$rc" == "0" ]]; then pass "wrapper exits 0 when the stub docker run succeeds"
else fail "wrapper exit code on success" "got $rc"; fi

if grep -q "LAKE_KEK_HEX" "$T/ok.argv" 2>/dev/null; then
  fail "LAKE_KEK_HEX never reaches docker run argv" "found: $(cat "$T/ok.argv")"
else
  pass "LAKE_KEK_HEX never reaches docker run argv"
fi
if grep -qF "$FAKE_KEK" "$T/ok.argv" 2>/dev/null; then
  fail "the raw KEK hex never reaches docker run argv" "found in: $(cat "$T/ok.argv")"
else
  pass "the raw KEK hex never reaches docker run argv"
fi
if grep -q -- "-e LAKE_KEK_FILE=/run/secrets/lake_kek" "$T/ok.argv" 2>/dev/null; then
  pass "LAKE_KEK_FILE=/run/secrets/lake_kek is passed instead"
else
  fail "LAKE_KEK_FILE=/run/secrets/lake_kek is passed instead" "argv: $(cat "$T/ok.argv" 2>/dev/null)"
fi
if [[ "$(cat "$T/ok.kekfile_mode" 2>/dev/null)" == "600" ]]; then
  pass "the KEK file was 0600 while docker run held it"
else
  fail "the KEK file was 0600 while docker run held it" "mode: $(cat "$T/ok.kekfile_mode" 2>/dev/null)"
fi
if [[ "$(cat "$T/ok.kekfile_content" 2>/dev/null)" == "$FAKE_KEK" ]]; then
  pass "the KEK file held the real hex"
else
  fail "the KEK file held the real hex"
fi
kek_path_ok="$(cat "$T/ok.kekfile_path" 2>/dev/null)"
if [[ -n "$kek_path_ok" && ! -e "$kek_path_ok" ]]; then
  pass "the KEK file is deleted after a successful run"
else
  fail "the KEK file is deleted after a successful run" "path: $kek_path_ok"
fi

# --- a failing run: the file must still be cleaned up -----------------------
rc="$(STUB_RUN_RC=7 run_wrapper fail "$FAKE_KEK")"
if [[ "$rc" == "7" ]]; then pass "wrapper propagates the stub docker run's exit code"
else fail "wrapper exit code on failure" "got $rc"; fi

kek_path_fail="$(cat "$T/fail.kekfile_path" 2>/dev/null)"
if [[ -n "$kek_path_fail" && ! -e "$kek_path_fail" ]]; then
  pass "the KEK file is deleted after a failing run"
else
  fail "the KEK file is deleted after a failing run" "path: $kek_path_fail"
fi

# --- no KEK exported at all: no file, no mount ------------------------------
rc="$(STUB_RUN_RC=0 run_wrapper nokek)"
if [[ "$rc" == "0" ]]; then pass "wrapper still runs with no KEK exported at all"
else fail "wrapper still runs with no KEK exported at all" "got $rc"; fi
if [[ -s "$T/nokek.kekfile_path" ]]; then
  fail "no KEK mount is added when LAKE_KEK_HEX is unset" "found: $(cat "$T/nokek.kekfile_path")"
else
  pass "no KEK mount is added when LAKE_KEK_HEX is unset"
fi

echo
if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails failure(s)"
  exit 1
fi
echo "all gmail.sh KEK-handling checks passed"
