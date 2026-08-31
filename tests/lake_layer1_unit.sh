#!/usr/bin/env bash
set -euo pipefail
# Unit tests for scripts/lake-skeleton.sh's layer-1 (LUKS) resolution —
# layer1_check and layer1_check_all (#4525, from #4301 F7). No docker, no root,
# no real block devices: `findmnt` and `lsblk` are shimmed on PATH so each case
# states exactly what the host would answer.
#
# Two properties, each of which the previous shape got wrong:
#   * dm-crypt BENEATH LVM is engaged. `lsblk -no TYPE <lv>` says "lvm" and
#     the old check called that NOT ENGAGED (a false SKIP — safe direction, but
#     the real lake's ceremony shape is exactly an LV on a LUKS PV).
#   * the lake is three bind mounts, not one root. A root on dm-crypt with a
#     data directory on a plain disk must not read as engaged.
#
# Usage: ./tests/lake_layer1_unit.sh
cd "$(dirname "${BASH_SOURCE[0]}")/.."
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export ASPIRANT_LAKE_SKELETON_LIB=1
export LAKE_SKELETON_ROOT="$TMPDIR_TEST/root"
# shellcheck disable=SC1091
source ./scripts/lake-skeleton.sh

PASS=0
FAIL=0
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1)); echo "[PASS] $label"
  else
    FAIL=$((FAIL + 1)); echo "[FAIL] $label"; echo "       want: $want"; echo "       got : $got"
  fi
}

# --- shims: a fake host whose answers are a table -------------------------
# DEVICE_OF maps a target path to what `findmnt -T` returns; CHAIN_OF maps a
# device to the `lsblk -sno TYPE` lines (top-down). Empty device = unresolvable.
SHIM="$TMPDIR_TEST/bin"; mkdir -p "$SHIM"
cat > "$SHIM/findmnt" <<'EOF'
#!/usr/bin/env bash
# findmnt -T <target> -no SOURCE
target="$2"
while IFS='=' read -r path dev; do
  [ "$path" = "$target" ] && { printf '%s\n' "$dev"; exit 0; }
done <<< "${DEVICE_OF:-}"
exit 1
EOF
cat > "$SHIM/lsblk" <<'EOF'
#!/usr/bin/env bash
# lsblk -sno TYPE <device>
dev="$3"
while IFS='=' read -r d chain; do
  [ "$d" = "$dev" ] && { printf '%s\n' "$chain" | tr ',' '\n'; exit 0; }
done <<< "${CHAIN_OF:-}"
exit 1
EOF
chmod +x "$SHIM/findmnt" "$SHIM/lsblk"
export PATH="$SHIM:$PATH"

rc_of() { local rc=0; "$@" >/dev/null || rc=$?; echo "$rc"; }

# --- layer1_check: one directory --------------------------------------------
export DEVICE_OF=$'/x/plain=/dev/sda\n/x/luks=/dev/mapper/lake_crypt\n/x/lv=/dev/mapper/vg-lake\n/x/raid=/dev/md0'
export CHAIN_OF=$'/dev/sda=disk\n/dev/mapper/lake_crypt=crypt,part,disk\n/dev/mapper/vg-lake=lvm,crypt,part,disk\n/dev/md0=raid1,disk,disk'

assert_eq "a plain disk is SKIP (rc 2)"                       2 "$(rc_of layer1_check /x/plain)"
assert_eq "a dm-crypt mapping is PASS (rc 0)"                 0 "$(rc_of layer1_check /x/luks)"
assert_eq "an LV on a LUKS PV is PASS — crypt beneath lvm"    0 "$(rc_of layer1_check /x/lv)"
assert_eq "RAID over plain disks is SKIP"                     2 "$(rc_of layer1_check /x/raid)"
assert_eq "an unresolvable path is FAIL (rc 1)"               1 "$(rc_of layer1_check /x/nowhere)"
assert_eq "the SKIP line names the chain it walked" \
  1 "$(layer1_check /x/lv >/dev/null; layer1_check /x/raid | grep -c 'raid1 disk disk')"
assert_eq "the PASS line says dm-crypt is in the chain" \
  1 "$(layer1_check /x/lv | grep -c 'dm-crypt engaged in the chain')"

# --- layer1_check_all: the three data directories ---------------------------
ROOT_T="$TMPDIR_TEST/lake"
mkdir -p "$ROOT_T/garage/data" "$ROOT_T/garage/meta" "$ROOT_T/catalog"

export DEVICE_OF="$ROOT_T/garage/data=/dev/mapper/vg-lake
$ROOT_T/garage/meta=/dev/mapper/vg-lake
$ROOT_T/catalog=/dev/mapper/lake_crypt"
assert_eq "all three data dirs on dm-crypt is PASS (rc 0)"    0 "$(rc_of layer1_check_all "$ROOT_T")"
assert_eq "and the summary says 3 of 3" \
  1 "$(layer1_check_all "$ROOT_T" | grep -c '3 of 3 data directories on dm-crypt')"

export DEVICE_OF="$ROOT_T/garage/data=/dev/sda
$ROOT_T/garage/meta=/dev/mapper/vg-lake
$ROOT_T/catalog=/dev/mapper/lake_crypt"
assert_eq "one data dir on a plain disk makes the whole layer SKIP (rc 2)" \
  2 "$(rc_of layer1_check_all "$ROOT_T")"
assert_eq "and the summary says 2 of 3" \
  1 "$(layer1_check_all "$ROOT_T" | grep -c '2 of 3 data directories on dm-crypt')"

# A root that resolves to dm-crypt must not vouch for a data dir that does not.
export DEVICE_OF="$ROOT_T=/dev/mapper/lake_crypt
$ROOT_T/garage/data=/dev/sda
$ROOT_T/garage/meta=/dev/sda
$ROOT_T/catalog=/dev/sda"
assert_eq "an encrypted root does not vouch for plain data dirs (rc 2)" \
  2 "$(rc_of layer1_check_all "$ROOT_T")"

export DEVICE_OF="$ROOT_T/garage/data=/dev/mapper/lake_crypt
$ROOT_T/garage/meta=/dev/mapper/lake_crypt"
assert_eq "a data dir that does not resolve is FAIL (rc 1), worse than SKIP" \
  1 "$(rc_of layer1_check_all "$ROOT_T")"

rm -rf "$ROOT_T/catalog"
assert_eq "a missing data dir is FAIL (rc 1)"                 1 "$(rc_of layer1_check_all "$ROOT_T")"
assert_eq "and it says so by path" \
  1 "$(layer1_check_all "$ROOT_T" | grep -c "$ROOT_T/catalog does not exist")"

echo
echo "lake_layer1_unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
