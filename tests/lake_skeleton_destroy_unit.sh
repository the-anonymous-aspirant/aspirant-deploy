#!/usr/bin/env bash
#
# `lake-skeleton.sh destroy` must not delete real data (system_3 #12471,
# child 2 of #11565). It used to `sudo rm -rf "$ROOT"` unconditionally; the
# skeleton now holds the operator's real records.
#
# No real docker and no real sudo. Fakes on PATH record every call: the fake
# docker succeeds silently, and the fake sudo performs an `rm -rf` only on a
# path inside this test's own temp directory, recording (and refusing)
# anything else. So a guard that fails here cannot delete anything outside
# the test.
#
# Usage: ./tests/lake_skeleton_destroy_unit.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
TMPDIR_TEST="$(realpath "$TMPDIR_TEST")"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $1"; }

FAKE_BIN="$TMPDIR_TEST/bin"
CALLS="$TMPDIR_TEST/calls.log"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$FAKE_CALLS"
exit 0
EOF
cat > "$FAKE_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$FAKE_CALLS"
if [ "${1:-}" = "rm" ]; then
  target="${!#}"
  case "$target" in
    "$FAKE_SAFE_PREFIX"/*) exec "$@" ;;
  esac
fi
echo "fake sudo: refusing '$*' outside the test directory" >&2
exit 97
EOF
chmod +x "$FAKE_BIN/docker" "$FAKE_BIN/sudo"

# Runs `lake-skeleton.sh destroy` on $1 with the fakes; extra args are
# VAR=value pairs for its environment. Sets RC.
run_destroy() {
  local root="$1"
  shift
  : > "$CALLS"
  RC=0
  env "$@" LAKE_SKELETON_ROOT="$root" FAKE_CALLS="$CALLS" \
    FAKE_SAFE_PREFIX="$TMPDIR_TEST" PATH="$FAKE_BIN:$PATH" \
    bash ./scripts/lake-skeleton.sh destroy >"$TMPDIR_TEST/out.log" 2>&1 || RC=$?
}

# A skeleton as `up` lays it out. $2: "data" puts a blob and a catalog file
# in it, "empty" leaves garage/data and catalog empty.
make_skeleton() {
  local root="$1" kind="$2"
  rm -rf "$root"
  mkdir -p "$root"/{config,garage/meta,garage/data,catalog,promote-spool}
  echo 'replication_factor = 1' > "$root/config/garage.toml"
  echo 'LAKE_S3_BUCKET=lake-skeleton-bronze' > "$root/lake-skeleton.env"
  if [ "$kind" = "data" ]; then
    mkdir -p "$root/garage/data/48/29" "$root/catalog/pgdata"
    echo 'a sealed blob' > "$root/garage/data/48/29/4829blob"
    echo 'catalog page' > "$root/catalog/pgdata/PG_VERSION"
  fi
}

refused_and_untouched() {
  local label="$1" root="$2"
  if [ "$RC" -eq 0 ]; then bad "$label: exit 0, want a refusal"; cat "$TMPDIR_TEST/out.log"; return; fi
  if [ -f "$root/garage/data/48/29/4829blob" ] && [ -f "$root/catalog/pgdata/PG_VERSION" ]; then
    ok "$label: refused, and the data is still there"
  else
    bad "$label: refused, but data was deleted"
  fi
  if [ -s "$CALLS" ]; then
    bad "$label: refused, but it called: $(tr '\n' ';' < "$CALLS")"
  else
    ok "$label: refused before stopping anything (no docker, no sudo)"
  fi
}

cleared() {
  local label="$1" root="$2"
  if [ "$RC" -ne 0 ]; then bad "$label: rc=$RC, want 0"; cat "$TMPDIR_TEST/out.log"; return; fi
  if [ -e "$root" ]; then bad "$label: exit 0, but $root still exists"; return; fi
  if grep -q '^docker compose .* down -v --remove-orphans' "$CALLS" && grep -q "^sudo rm -rf -- $root\$" "$CALLS"; then
    ok "$label: stopped the stack and deleted $root"
  else
    bad "$label: calls were: $(tr '\n' ';' < "$CALLS")"
  fi
}

ROOT_DIR="$TMPDIR_TEST/scratch/lake-skeleton"

# --- 1. A skeleton holding data, with no marker, is refused -----------------
make_skeleton "$ROOT_DIR" data
run_destroy "$ROOT_DIR"
refused_and_untouched "real data, no confirmation" "$ROOT_DIR"
if grep -q "LAKE_SKELETON_DESTROY_REAL_DATA=$ROOT_DIR" "$TMPDIR_TEST/out.log"; then
  ok "the refusal names the confirmation and the exact path"
else
  bad "the refusal does not name the confirmation: $(cat "$TMPDIR_TEST/out.log")"
fi

# --- 2. A confirmation that is not the exact resolved path is refused -------
for wrong in 1 yes true "$ROOT_DIR/" "$TMPDIR_TEST/scratch" "$TMPDIR_TEST/scratch/lake-skeleton2"; do
  make_skeleton "$ROOT_DIR" data
  run_destroy "$ROOT_DIR" "LAKE_SKELETON_DESTROY_REAL_DATA=$wrong"
  refused_and_untouched "confirmation '$wrong'" "$ROOT_DIR"
done

# --- 3. The explicit confirmation deletes it --------------------------------
make_skeleton "$ROOT_DIR" data
run_destroy "$ROOT_DIR" "LAKE_SKELETON_DESTROY_REAL_DATA=$ROOT_DIR"
cleared "real data, confirmed with its exact path" "$ROOT_DIR"

# --- 4. An empty skeleton is still cleared without confirmation -------------
make_skeleton "$ROOT_DIR" empty
run_destroy "$ROOT_DIR"
cleared "empty skeleton" "$ROOT_DIR"

# --- 5. A fixture-only skeleton (marker present) is cleared -----------------
make_skeleton "$ROOT_DIR" data
echo marker > "$ROOT_DIR/.fixtures-only"
run_destroy "$ROOT_DIR"
cleared "fixture-only skeleton" "$ROOT_DIR"

# --- 6. A root that does not exist is fine -----------------------------------
rm -rf "$ROOT_DIR"
run_destroy "$ROOT_DIR"
if [ "$RC" -eq 0 ]; then ok "a missing root: exit 0"; else bad "a missing root: rc=$RC"; fi

# --- 7. A directory that is not the skeleton's own is refused, even confirmed
make_skeleton "$ROOT_DIR" empty
echo 'not the skeleton' > "$ROOT_DIR/notes.txt"
run_destroy "$ROOT_DIR" "LAKE_SKELETON_DESTROY_REAL_DATA=$ROOT_DIR"
if [ "$RC" -ne 0 ] && [ -f "$ROOT_DIR/notes.txt" ] && [ ! -s "$CALLS" ]; then
  ok "a foreign entry: refused even with the confirmation, nothing touched"
else
  bad "a foreign entry: rc=$RC calls=$(tr '\n' ';' < "$CALLS")"
fi
rm -f "$ROOT_DIR/notes.txt"

# A hidden foreign entry counts too.
echo x > "$ROOT_DIR/.bash_history"
run_destroy "$ROOT_DIR"
if [ "$RC" -ne 0 ] && [ -f "$ROOT_DIR/.bash_history" ] && [ ! -s "$CALLS" ]; then
  ok "a hidden foreign entry: refused"
else
  bad "a hidden foreign entry: rc=$RC"
fi
rm -f "$ROOT_DIR/.bash_history"

# --- 8. Shallow and real-lake paths are refused before any listing ----------
# The fake sudo would refuse these anyway; the guard must refuse first.
for root in / /tmp /scratch /lake /data /data/lake-skeleton; do
  run_destroy "$root" "LAKE_SKELETON_DESTROY_REAL_DATA=$root"
  if [ "$RC" -ne 0 ] && [ ! -s "$CALLS" ]; then
    ok "root '$root': refused before stopping anything"
  else
    bad "root '$root': rc=$RC calls=$(tr '\n' ';' < "$CALLS")"
  fi
done

# --- 9. A symlink cannot point the delete at real data ----------------------
REAL="$TMPDIR_TEST/elsewhere/lake-skeleton"
make_skeleton "$REAL" data
ln -s "$REAL" "$TMPDIR_TEST/scratch/link"
run_destroy "$TMPDIR_TEST/scratch/link" "LAKE_SKELETON_DESTROY_REAL_DATA=$TMPDIR_TEST/scratch/link"
refused_and_untouched "a symlink, confirmed with the link's own path" "$REAL"
rm -f "$TMPDIR_TEST/scratch/link"

# --- 10. The marker's lifecycle ----------------------------------------------
# A verb that can bring real data drops the marker before it runs, even when
# it then fails. Run for real only where the verb is harmless with fakes:
# ingest without a manifest stops at its usage line, and an unknown verb at
# the help text. The rest are checked through the dispatcher's helper.
run_verb() {
  local root="$1"
  shift
  : > "$CALLS"
  LAKE_SKELETON_ROOT="$root" FAKE_CALLS="$CALLS" FAKE_SAFE_PREFIX="$TMPDIR_TEST" \
    ASPIRANT_DEPLOY_ENV_FILE="$TMPDIR_TEST/deploy.env" \
    PATH="$FAKE_BIN:$PATH" bash ./scripts/lake-skeleton.sh "$@" >"$TMPDIR_TEST/out.log" 2>&1 || true
}
for verb in ingest some-future-verb; do
  make_skeleton "$ROOT_DIR" data
  echo marker > "$ROOT_DIR/.fixtures-only"
  run_verb "$ROOT_DIR" "$verb"
  if [ -e "$ROOT_DIR/.fixtures-only" ]; then bad "'$verb' kept the fixtures-only marker"; else ok "'$verb' dropped the fixtures-only marker"; fi
done
for verb in status down; do
  make_skeleton "$ROOT_DIR" data
  echo marker > "$ROOT_DIR/.fixtures-only"
  run_verb "$ROOT_DIR" "$verb"
  if [ -e "$ROOT_DIR/.fixtures-only" ]; then ok "'$verb' kept the marker"; else bad "'$verb' dropped the marker"; fi
done
(
  export ASPIRANT_LAKE_SKELETON_LIB=1
  # shellcheck disable=SC1091
  LAKE_SKELETON_ROOT="$ROOT_DIR" source ./scripts/lake-skeleton.sh
  for verb in ingest promote list-staged link-gmail explorer-env rotate-explorer-ro explorer-decrypt-up seed verify verify-at-rest up; do
    echo marker > "$ROOT/.fixtures-only"
    drop_fixtures_marker_for_verb "$verb"
    if [ -e "$ROOT/.fixtures-only" ]; then echo "$verb kept"; else echo "$verb dropped"; fi
  done
) > "$TMPDIR_TEST/drop.out" 2>&1
want="ingest dropped promote dropped list-staged dropped link-gmail dropped explorer-env dropped rotate-explorer-ro dropped explorer-decrypt-up dropped seed kept verify kept verify-at-rest kept up kept "
if [ "$(tr '\n' ' ' < "$TMPDIR_TEST/drop.out")" = "$want" ]; then
  ok "real-data verbs drop the marker; fixture and read-only verbs keep it"
else
  bad "marker by verb: $(tr '\n' ' ' < "$TMPDIR_TEST/drop.out")"
fi
if grep -q '^drop_fixtures_marker_for_verb "\${1:-}"$' scripts/lake-skeleton.sh; then
  ok "the dispatcher calls drop_fixtures_marker_for_verb before the verb"
else
  bad "the dispatcher no longer calls drop_fixtures_marker_for_verb"
fi

# up writes the marker on a fresh root only (the helpers, sourced: up itself
# needs a real stack).
(
  export ASPIRANT_LAKE_SKELETON_LIB=1
  # shellcheck disable=SC1091
  LAKE_SKELETON_ROOT="$TMPDIR_TEST/fresh" source ./scripts/lake-skeleton.sh
  mkdir -p "$ROOT"
  mark_fixtures_only_if_fresh 1
  [ -f "$ROOT/.fixtures-only" ] && echo FRESH-MARKED
  rm -f "$ROOT/.fixtures-only"
  mark_fixtures_only_if_fresh 0
  [ -f "$ROOT/.fixtures-only" ] || echo OLD-UNMARKED
) > "$TMPDIR_TEST/lib.out" 2>&1
if [ "$(tr '\n' ' ' < "$TMPDIR_TEST/lib.out")" = "FRESH-MARKED OLD-UNMARKED " ]; then
  ok "up marks a fresh root only"
else
  bad "up's marker: $(cat "$TMPDIR_TEST/lib.out")"
fi
if grep -q 'root_was_fresh=1' scripts/lake-skeleton.sh && grep -q 'mark_fixtures_only_if_fresh "\$root_was_fresh"' scripts/lake-skeleton.sh; then
  ok "up reads whether ROOT existed before seed_config creates it"
else
  bad "up no longer passes root_was_fresh to mark_fixtures_only_if_fresh"
fi

echo
echo "lake_skeleton_destroy_unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
