#!/usr/bin/env bash
set -euo pipefail

# Unit tests for scripts/e2e-stack.sh (system_3 #9980): the security rules of
# the #9979 ruling, checked without docker. `docker`, `curl`, `ss` and the
# seed are stubbed on PATH; the docker stub records every argv it receives,
# so the test can read exactly what the script would have run.
#
# Usage: ./tests/e2e_stack_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
BIN="$T/bin"
mkdir -p "$BIN"
LOG="$T/docker-argv.log"

cat >"$BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_ARGV_LOG"
case "$1 $2" in
  "ps --filter") echo aspirant-online-client-green-1 ;;
  "ps -aq") echo c1 c2 c3 ;;
  "network ls" | "volume ls") echo s3e2e-x ;;
esac
case "$1" in
  inspect)
    case "$*" in
      *'.Image'*) echo "sha256:feedface$4" ;;
      *revision*) echo "0123456789abcdef" ;;
      *) echo ok ;;
    esac ;;
  # Only `docker exec -i` gets piped input (the logins' SQL); draining stdin
  # on any other exec would block forever on an open terminal.
  exec)
    case " $* " in *" -i "*) in="$(cat 2>/dev/null || true)"; case "$in" in *"count(*)"*) echo 3 ;; esac ;; esac
    case "$*" in *pg_isready*) [ -n "${STUB_PG_FAIL:-}" ] && exit 1 ;; esac ;;
esac
exit 0
EOF
cat >"$BIN/curl" <<'EOF'
#!/usr/bin/env bash
echo 200
EOF
cat >"$BIN/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$BIN/python3" <<'EOF'
#!/usr/bin/env bash
echo "seeded: (stub)"
EOF
chmod +x "$BIN"/*

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }

export DOCKER_ARGV_LOG="$LOG"
export E2E_STACK_ROOT="$T/root"
OUT="$T/up.out"
PATH="$BIN:$PATH" ./scripts/e2e-stack.sh up >"$OUT" 2>&1 || { cat "$OUT"; bad "up exits 0"; }
[ "$FAIL" -eq 0 ] && ok "up exits 0"

RUN="$(sed -n 's/^e2e-stack run: \([0-9a-f-]*\) .*/\1/p' "$OUT")"
[ -n "$RUN" ] && ok "up prints the 'e2e-stack run:' line" || bad "up prints the 'e2e-stack run:' line"
DIR="$E2E_STACK_ROOT/$RUN"

# 1. Isolation: every publish on loopback, never the prod network or prod files.
pubs="$(grep -oE -- '-p [^ ]+' "$LOG" || true)"
[ -n "$pubs" ] && ! grep -vqE -- '-p 127\.0\.0\.1:[0-9]+:' <<<"$pubs" && ok "every publish is 127.0.0.1" || bad "every publish is 127.0.0.1 ($pubs)"
! grep -q 'aspirant-online_default' "$LOG" && ok "never joins aspirant-online_default" || bad "never joins aspirant-online_default"
! grep -qE -- '-v [^ ]*(\.env|/data/aspirant|aspirant-online)' "$LOG" && ok "mounts no .env and no prod volume" || bad "mounts no .env and no prod volume"
! grep -qE '(docker )?exec [^ ]*aspirant-online|inspect .*Config\.Env' "$LOG" && ok "never execs into or reads the env of a served container" || bad "never execs into or reads the env of a served container"

# 3. Per-run secrets: 0600 files, values never printed and never on an argv.
for f in db.env server.env run.env; do
  m="$(stat -c '%a' "$DIR/$f" 2>/dev/null || echo missing)"
  [ "$m" = 600 ] && ok "$f is 0600" || bad "$f is 0600 (got $m)"
done
leaks=0
checked=0
while IFS='=' read -r k v; do
  case "$k" in *PASSWORD | JWT_SECRET) ;; *) continue ;; esac
  checked=$((checked + 1))
  grep -qF "$v" "$OUT" && leaks=$((leaks + 1))
  grep -qF "$v" "$LOG" && leaks=$((leaks + 1))
done < <(cat "$DIR"/*.env)
[ "$checked" -ge 5 ] && ok "secrets checked ($checked)" || bad "secrets checked ($checked, want >= 5)"
[ "$leaks" -eq 0 ] && ok "no secret in stdout, stderr or any docker argv" || bad "no secret in stdout, stderr or any docker argv ($leaks)"
grep -q -- '--env-file' "$LOG" && ok "secrets reach containers by --env-file" || bad "secrets reach containers by --env-file"

# 4. Both sides of the gate: the three logins exist in the run's env.
for k in E2E_OWNER=vinoly E2E_ADMIN=e2e_admin E2E_MEMBER=e2e_member; do
  grep -qx "$k" "$DIR/run.env" && ok "login $k" || bad "login $k"
done

# The bootstrap window is closed: the client (the only publish) starts after
# the logins are written, so /bootstrap/admin is never reachable while the
# users table is empty.
ins="$(grep -n 'exec -i s3e2e-.*-db psql' "$LOG" | head -1 | cut -d: -f1)"
cli="$(grep -n 'run -d --name s3e2e-.*-client' "$LOG" | head -1 | cut -d: -f1)"
[ -n "$ins" ] && [ -n "$cli" ] && [ "$ins" -lt "$cli" ] && ok "the client is published only after the logins exist" || bad "the client is published only after the logins exist (insert@$ins client@$cli)"
# Rule 5, literally: the served server is inspected only with a format.
! grep -qE '^inspect aspirant-online' "$LOG" && ok "served containers are inspected only with -f" || bad "served containers are inspected only with -f"

# Served images are pinned by ID, not by tag.
grep -qE 'run -d .*sha256:feedface' "$LOG" && ok "served images run by image ID" || bad "served images run by image ID"
! grep -qE 'run -d .*aspirant-(server|client):latest' "$LOG" && ok "no :latest tag is run" || bad "no :latest tag is run"

# down removes what up made, and is idempotent.
: >"$LOG"
PATH="$BIN:$PATH" ./scripts/e2e-stack.sh down "$RUN" >/dev/null 2>&1 && ok "down exits 0" || bad "down exits 0"
[ ! -e "$DIR" ] && ok "down deletes the run directory and its secrets" || bad "down deletes the run directory and its secrets"
grep -q "label=org.aspirant.e2e-stack.run=$RUN" "$LOG" && ok "down selects by the run's label" || bad "down selects by the run's label"
PATH="$BIN:$PATH" ./scripts/e2e-stack.sh down "$RUN" >/dev/null 2>&1 && ok "down again exits 0" || bad "down again exits 0"
PATH="$BIN:$PATH" ./scripts/e2e-stack.sh down '../etc' >/dev/null 2>&1 && bad "down refuses a non-run id" || ok "down refuses a non-run id"

# A failed up removes what it created (postgres never becomes ready).
: >"$LOG"
FOUT="$T/up-fail.out"
if STUB_PG_FAIL=1 PATH="$BIN:$PATH" ./scripts/e2e-stack.sh up >"$FOUT" 2>&1; then bad "a failed up exits non-zero"; else ok "a failed up exits non-zero"; fi
FRUN="$(sed -n 's/^e2e-stack: up failed; removing run \([0-9a-f-]*\)$/\1/p' "$FOUT")"
[ -n "$FRUN" ] && ok "a failed up says it is removing its run" || bad "a failed up says it is removing its run ($(tail -2 "$FOUT"))"
grep -q "label=org.aspirant.e2e-stack.run=$FRUN" "$LOG" && grep -q '^rm -f' "$LOG" && ok "a failed up removes its containers" || bad "a failed up removes its containers"
[ ! -e "$E2E_STACK_ROOT/$FRUN" ] && ok "a failed up deletes its secrets" || bad "a failed up deletes its secrets"

# A state root that is a symlink is refused (a planted one would redirect the secrets).
ln -s "$T/elsewhere" "$T/linkroot"
if E2E_STACK_ROOT="$T/linkroot" PATH="$BIN:$PATH" ./scripts/e2e-stack.sh up >/dev/null 2>&1; then bad "a symlinked state root is refused"; else ok "a symlinked state root is refused"; fi
[ ! -e "$T/elsewhere" ] && ok "nothing is written through the symlink" || bad "nothing is written through the symlink"

echo "e2e_stack_unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
