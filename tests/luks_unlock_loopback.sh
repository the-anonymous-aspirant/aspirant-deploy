#!/usr/bin/env bash
#
# luks_unlock_loopback.sh — self-contained verification for
# scripts/luks-unlock/unlock.sh (task #4132 / #4120-B).
#
# Exercises unlock.sh's core operations (open_one / mount_one / is_open /
# is_mounted / unmount_one / close_one) against a throwaway LUKS device backed by
# a loopback file. It NEVER touches /dev/sda, /dev/md0, the lake LV, or any real
# volume — the parameterised functions are called with the loop device directly.
#
# Requires root (cryptsetup/losetup/mount) + a free loop device. Prints
# [PASS]/[FAIL] per check and exits non-zero if any check fails, per the
# aspirant-deploy per-repo verify convention (tests/*.sh).
#
# Run:  sudo tests/luks_unlock_loopback.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNLOCK="$HERE/../scripts/luks-unlock/unlock.sh"

rc=0
pass() { printf '  [PASS] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; rc=1; }

[[ -f "$UNLOCK" ]] || { echo "cannot find unlock.sh at $UNLOCK"; exit 2; }
if [[ $EUID -ne 0 ]]; then
  echo "  [FAIL] must run as root (cryptsetup/losetup/mount) — use: sudo $0"
  exit 2
fi

PASS_PHRASE="loopback-self-test-passphrase"
MAP="luks_unlock_selftest"
WORK="$(mktemp -d)"
IMG="$WORK/luks.img"
PLAINIMG="$WORK/plain.img"
TESTMNT="$WORK/mnt"
LOOP=""
PLAINLOOP=""

cleanup() {
  set +e
  mountpoint -q "$TESTMNT" && umount "$TESTMNT"
  cryptsetup status "$MAP" >/dev/null 2>&1 && cryptsetup luksClose "$MAP"
  [[ -n "$LOOP" ]]      && losetup -d "$LOOP" 2>/dev/null
  [[ -n "$PLAINLOOP" ]] && losetup -d "$PLAINLOOP" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "=== setup: throwaway LUKS loopback ==="
dd if=/dev/zero of="$IMG" bs=1M count=32 status=none
LOOP="$(losetup --find --show "$IMG")"
printf '%s' "$PASS_PHRASE" | cryptsetup luksFormat --batch-mode "$LOOP" -
pass "created LUKS loopback $LOOP"

# Source unlock.sh — the main-guard means only its functions load, main does not run.
# shellcheck disable=SC1090
source "$UNLOCK"

echo "=== open_one ==="
if open_one "$MAP" "$LOOP" <<<"$PASS_PHRASE" >/dev/null && is_open "$MAP"; then
  pass "open_one unlocked the container"
else
  fail "open_one did not unlock the container"
fi

echo "=== open_one idempotency (already open) ==="
if open_one "$MAP" "$LOOP" >/dev/null && is_open "$MAP"; then
  pass "open_one is a no-op when already unlocked"
else
  fail "open_one failed on an already-open mapping"
fi

echo "=== mount_one ==="
mkfs.ext4 -q "/dev/mapper/$MAP"
if mount_one "$MAP" "$TESTMNT" >/dev/null && is_mounted "$TESTMNT"; then
  pass "mount_one mounted the opened mapper"
else
  fail "mount_one did not mount the mapper"
fi

echo "=== mount_one idempotency (already mounted) ==="
if mount_one "$MAP" "$TESTMNT" >/dev/null && is_mounted "$TESTMNT"; then
  pass "mount_one is a no-op when already mounted"
else
  fail "mount_one failed on an already-mounted path"
fi

echo "=== data round-trips through the unlocked volume ==="
echo "canary-4132" > "$TESTMNT/canary"
sync
if [[ "$(cat "$TESTMNT/canary")" == "canary-4132" ]]; then
  pass "wrote and read back a file on the mounted volume"
else
  fail "canary read-back mismatch"
fi

echo "=== teardown: unmount_one + close_one ==="
unmount_one "$TESTMNT"
close_one "$MAP"
if ! is_mounted "$TESTMNT" && ! is_open "$MAP"; then
  pass "unmount_one + close_one returned to a locked, unmounted state"
else
  fail "teardown left the volume open or mounted"
fi

echo "=== open_one rejects a non-LUKS device (guard) ==="
dd if=/dev/zero of="$PLAINIMG" bs=1M count=8 status=none
PLAINLOOP="$(losetup --find --show "$PLAINIMG")"
if ( open_one "nonluks_selftest" "$PLAINLOOP" ) >/dev/null 2>&1; then
  fail "open_one accepted a non-LUKS device (isLuks guard did not fire)"
  cryptsetup luksClose "nonluks_selftest" 2>/dev/null || true
else
  pass "open_one refused a non-LUKS backing device"
fi

echo "=== open_one rejects a missing device (guard) ==="
if ( open_one "missing_selftest" "/dev/does-not-exist-4132" ) >/dev/null 2>&1; then
  fail "open_one accepted a nonexistent device"
else
  pass "open_one refused a nonexistent backing device"
fi

echo "=== summary ==="
if [[ "$rc" -eq 0 ]]; then
  echo "  all unlock.sh core operations verified against the loopback."
else
  echo "  one or more checks FAILED."
fi
exit "$rc"
