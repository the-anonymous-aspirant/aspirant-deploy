#!/usr/bin/env bash
set -euo pipefail

# The failed-import copies mount and its host backstop (system_3 #10563).
#
# aspirant-server keeps a copy of each failed invoice-import upload, the app
# user's own bank documents, for at most 168 hours (system_3 #10536). Security
# ruled where those copies may live (c65222 §1 on #10536) and what the deploy
# side must add (c65555 on #10563). This test pins both:
#
#   compose  - in every committed docker-compose*.yml, only `server` mounts
#              /data/aspirant/import-failures; no service mounts an ancestor of
#              it (which would expose it too; one read-only exception, see
#              KNOWN_ANCESTORS); it is writable; server's
#              IMPORT_FAILURE_COPIES_DIR is the mount's container path; and
#              that path is not inside another server mount (assets/, files/).
#   backstop - scripts/import-failures-backstop.sh deletes every file older
#              than 168 h by mtime, nested ones too, keeps younger ones, is a
#              no-op on a missing directory, and fails loudly when it cannot
#              delete or read something.
#
# Each compose rule has a negative control, so a check that cannot fail is
# caught.
#
# Usage: ./tests/import_failures_unit.sh

cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
cleanup() {
  chmod -R u+rwx "$TMPDIR_TEST" 2>/dev/null || true
  rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

PASS=0
FAIL=0

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

# check_file <path> <require_server_mount: yes|no>: prints one line per
# violation, exits non-zero on any. docker-compose.yml must carry the mount;
# the other committed compose files must simply not expose it.
check_file() {
  python3 - "$1" "$2" <<'EOF'
import sys
import yaml

HOST = "/data/aspirant/import-failures"
# The one ancestor mount allowed, and only read-only: aspirant-monitor's
# `/data:/host/data:ro`, which its /disk route walks to size each
# /data/aspirant/* directory. It predates the copies. Narrowed by system_3
# #10568-A3: monitor now runs as a dedicated non-root uid with every
# capability dropped, so 0700/0600 (import-failures, backups/) and 0700
# directories do stop it — the mount stays allowed because what it can
# actually read is now gated by those same file modes, not by this
# exception. No other service, and no writable variant, is allowed.
KNOWN_ANCESTORS = {("monitor", "/data", True)}

path, require = sys.argv[1], sys.argv[2] == "yes"
services = (yaml.safe_load(open(path)) or {}).get("services") or {}
bad = []


def norm(p):
    p = str(p).rstrip("/")
    return p or "/"


def mounts(spec):
    """(source, target, read_only) for every bind in a service."""
    for v in spec.get("volumes") or []:
        if isinstance(v, dict):
            if v.get("type", "bind") != "bind":
                continue
            yield norm(v.get("source", "")), norm(v.get("target", "")), bool(v.get("read_only"))
        else:
            parts = str(v).split(":")
            if len(parts) < 2 or not parts[0].startswith("/"):
                continue
            yield norm(parts[0]), norm(parts[1]), len(parts) > 2 and "ro" in parts[2].split(",")


def env_of(spec):
    env = spec.get("environment") or {}
    if isinstance(env, dict):
        return {k: v for k, v in env.items()}
    return dict((e.split("=", 1) + [""])[:2] for e in env)


server_target = None
for name, spec in services.items():
    spec = spec or {}
    for src, tgt, ro in mounts(spec):
        exposes = src == HOST or src.startswith(HOST + "/")
        ancestor = HOST.startswith(src + "/") or src == "/"
        if ancestor:
            if (name, src, ro) in KNOWN_ANCESTORS:
                print(f"NOTE: {name} mounts {src} read-only, an ancestor of {HOST} "
                      "(known, pre-existing; see KNOWN_ANCESTORS)", file=sys.stderr)
            else:
                bad.append(f"{name} mounts {src}, an ancestor of {HOST}")
        if not exposes:
            continue
        if name != "server":
            bad.append(f"{name} mounts {src}; only server may")
            continue
        if src != HOST:
            bad.append(f"server mounts {src}, a subdirectory, not {HOST} itself")
        if ro:
            bad.append("server mounts the copies read-only; it writes and deletes them")
        server_target = tgt

server = services.get("server") or {}
copies_dir = env_of(server).get("IMPORT_FAILURE_COPIES_DIR")
if require:
    if server_target is None:
        bad.append(f"server does not mount {HOST}")
    if copies_dir is None:
        bad.append("server does not set IMPORT_FAILURE_COPIES_DIR")
    elif server_target is not None and norm(copies_dir) != server_target:
        bad.append(f"IMPORT_FAILURE_COPIES_DIR={copies_dir} is not the mount target {server_target}")
elif copies_dir is not None and server_target is None:
    bad.append("server sets IMPORT_FAILURE_COPIES_DIR without the mount")

# The copies directory must not sit inside another of server's mounts (e.g.
# /data/assets, which GET /fetch-object/:etag serves to every Trusted user).
if copies_dir is not None:
    cd = norm(copies_dir)
    for src, tgt, ro in mounts(server):
        if src == HOST:
            continue
        if cd == tgt or cd.startswith(tgt + "/"):
            bad.append(f"IMPORT_FAILURE_COPIES_DIR={copies_dir} is inside server's {src}:{tgt} mount")

for line in bad:
    print(line)
sys.exit(1 if bad else 0)
EOF
}

echo "== compose: negative controls"

write() { cat > "$TMPDIR_TEST/$1.yml"; }

write other_service <<'EOF'
services:
  server:
    environment: {IMPORT_FAILURE_COPIES_DIR: /data/import-failures}
    volumes: ["/data/aspirant/import-failures:/data/import-failures"]
  browser:
    volumes: ["/data/aspirant/import-failures:/data/x:ro"]
EOF
write ancestor <<'EOF'
services:
  server:
    environment: {IMPORT_FAILURE_COPIES_DIR: /data/import-failures}
    volumes: ["/data/aspirant/import-failures:/data/import-failures"]
  monitor:
    volumes: ["/data/aspirant:/host-data:ro"]
EOF
write ancestor_new_service <<'EOF'
services:
  server:
    environment: {IMPORT_FAILURE_COPIES_DIR: /data/import-failures}
    volumes: ["/data/aspirant/import-failures:/data/import-failures"]
  advisor:
    volumes: ["/data:/host/data:ro"]
EOF
write ancestor_monitor_rw <<'EOF'
services:
  server:
    environment: {IMPORT_FAILURE_COPIES_DIR: /data/import-failures}
    volumes: ["/data/aspirant/import-failures:/data/import-failures"]
  monitor:
    volumes: ["/data:/host/data"]
EOF
write long_form_other <<'EOF'
services:
  server:
    environment: {IMPORT_FAILURE_COPIES_DIR: /data/import-failures}
    volumes: ["/data/aspirant/import-failures:/data/import-failures"]
  advisor:
    volumes:
      - {type: bind, source: /data/aspirant/import-failures/, target: /x}
EOF
write under_assets <<'EOF'
services:
  server:
    environment: {IMPORT_FAILURE_COPIES_DIR: /data/assets/import-failures}
    volumes:
      - /data/aspirant/assets:/data/assets
      - /data/aspirant/import-failures:/data/assets/import-failures
EOF
write read_only <<'EOF'
services:
  server:
    environment: {IMPORT_FAILURE_COPIES_DIR: /data/import-failures}
    volumes: ["/data/aspirant/import-failures:/data/import-failures:ro"]
EOF
write env_mismatch <<'EOF'
services:
  server:
    environment: {IMPORT_FAILURE_COPIES_DIR: /data/somewhere-else}
    volumes: ["/data/aspirant/import-failures:/data/import-failures"]
EOF
write env_missing <<'EOF'
services:
  server:
    volumes: ["/data/aspirant/import-failures:/data/import-failures"]
EOF
write mount_missing <<'EOF'
services:
  server:
    environment: {IMPORT_FAILURE_COPIES_DIR: /data/import-failures}
EOF

for bad in other_service ancestor ancestor_new_service ancestor_monitor_rw long_form_other under_assets read_only env_mismatch env_missing mount_missing; do
  if check_file "$TMPDIR_TEST/$bad.yml" yes >/dev/null; then
    record no "negative control ($bad): the check refuses it"
  else
    record yes "negative control ($bad): the check refuses it"
  fi
done

write good <<'EOF'
services:
  server:
    environment:
      - IMPORT_FAILURE_COPIES_DIR=/data/import-failures
    volumes:
      - /data/aspirant/files:/data/files
      - /data/aspirant/assets:/data/assets
      - /data/aspirant/import-failures:/data/import-failures
  browser:
    volumes: ["/data/aspirant/files:/data/files"]
  monitor:
    volumes: ["/data:/host/data:ro"]
EOF
if check_file "$TMPDIR_TEST/good.yml" yes >/dev/null 2>&1; then
  record yes "positive control: server alone mounts the copies, env matches"
else
  record no "positive control: server alone mounts the copies, env matches"
fi

echo "== compose: committed files"
for f in docker-compose*.yml; do
  require=no
  [[ "$f" == "docker-compose.yml" ]] && require=yes
  if out="$(check_file "$f" "$require")"; then
    record yes "$f: copies mounted into server only (required here: $require)"
  else
    record no "$f: copies mounted into server only (required here: $require)"
    printf '%s\n' "$out" | sed 's/^/        /'
  fi
done

echo "== backstop"
BACKSTOP="$PWD/scripts/import-failures-backstop.sh"

run_backstop() {
  local dir="$1"
  set +e
  OUT="$(IMPORT_FAILURE_HOST_DIR="$dir" bash "$BACKSTOP" 2>&1)"
  RC=$?
  set -e
}

D="$TMPDIR_TEST/copies"
mkdir -m 700 "$D" "$D/nested"
touch -d '8 days ago' "$D/old" "$D/nested/old-nested"
touch -d '7 days ago 1 hour ago' "$D/just-past"
touch -d '6 days ago' "$D/young"
touch "$D/fresh"
run_backstop "$D"
[[ $RC -eq 0 ]] && record yes "sweep exits 0" || { record no "sweep exits 0 (rc=$RC)"; echo "$OUT"; }
for gone in old nested/old-nested just-past; do
  [[ ! -e "$D/$gone" ]] && record yes "deletes $gone (past 168 h)" || record no "deletes $gone (past 168 h)"
done
for kept in young fresh; do
  [[ -e "$D/$kept" ]] && record yes "keeps $kept (within 168 h)" || record no "keeps $kept (within 168 h)"
done
grep -q 'deleted=3 failed=0 unreadable=0' <<<"$OUT" \
  && record yes "summary line counts 3 deleted" || { record no "summary line counts 3 deleted"; echo "$OUT"; }

run_backstop "$TMPDIR_TEST/does-not-exist"
[[ $RC -eq 0 ]] && grep -q 'absent' <<<"$OUT" \
  && record yes "missing directory: exit 0, nothing swept" || record no "missing directory: exit 0 (rc=$RC)"

ln -s "$D" "$TMPDIR_TEST/link"
run_backstop "$TMPDIR_TEST/link"
[[ $RC -eq 2 ]] && record yes "symlinked directory: refused (exit 2)" || record no "symlinked directory: refused (rc=$RC)"

chmod 755 "$D"
run_backstop "$D"
grep -q 'WARNING: .* mode 755' <<<"$OUT" \
  && record yes "wrong mode is reported" || record no "wrong mode is reported"
chmod 700 "$D"

if [[ "$(id -u)" != "0" ]]; then
  mkdir "$D/locked"
  touch -d '8 days ago' "$D/locked/stuck"
  chmod 500 "$D/locked"
  run_backstop "$D"
  [[ $RC -eq 1 ]] && grep -q 'FAILED to delete locked/stuck' <<<"$OUT" \
    && record yes "undeletable old file: exit 1, named" || { record no "undeletable old file: exit 1 (rc=$RC)"; echo "$OUT"; }
  chmod 700 "$D/locked"
  rm -rf "$D/locked"

  mkdir "$D/unreadable"
  touch -d '8 days ago' "$D/unreadable/hidden"
  chmod 000 "$D/unreadable"
  run_backstop "$D"
  [[ $RC -eq 1 ]] && grep -q 'unreadable=1' <<<"$OUT" \
    && record yes "unreadable subdirectory: exit 1, not a quiet skip" || { record no "unreadable subdirectory: exit 1 (rc=$RC)"; echo "$OUT"; }
  chmod 700 "$D/unreadable"
else
  echo "  SKIP  permission cases (running as root)"
fi

grep -q '^MAX_AGE_MINUTES=10080$' "$BACKSTOP" \
  && record yes "ceiling is 10080 min = aspirant-server's 168 h importFailureMaxWindowHours" \
  || record no "ceiling is 10080 min = aspirant-server's 168 h importFailureMaxWindowHours"

echo
echo "import_failures_unit: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
