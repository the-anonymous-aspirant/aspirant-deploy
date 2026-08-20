#!/usr/bin/env bash
#
# inventory.sh — read-only state enumeration for the LUKS layer-1 targets.
#
# Part of DATA_LAKE_DESIGN.md §9 layer 1 (task #4131 / #4120-A). Run this on the
# cell before the encryption ceremony to confirm the layout the playbook assumes
# still holds. It writes nothing and changes nothing — every command here reads.
#
# Usage: sudo ./inventory.sh            # sudo only so cryptsetup/mdadm can read;
#                                        # no privileged *write* is performed.
set -euo pipefail

# The three layer-1 targets, as they exist today (verified 2026-08-19):
#   /data    -> md0  RAID1 (sdb+sdc), rotational HDD, real production data
#   /scratch -> sda  raw ext4, rotational HDD, synthetic-only
#   lake LV  -> to be carved from VG ubuntu-vg-1 free extents on the SSD (sdd)
DATA_MOUNT=/data
SCRATCH_MOUNT=/scratch
LAKE_VG=ubuntu-vg-1

rule() { printf '\n=== %s ===\n' "$1"; }

rule "block topology"
lsblk -o NAME,SIZE,TYPE,FSTYPE,ROTA,MOUNTPOINT

rule "mounts + fill for the layer-1 targets"
df -hT "$DATA_MOUNT" "$SCRATCH_MOUNT" 2>/dev/null || true

rule "RAID health (/data = md0)"
cat /proc/mdstat

rule "LVM — free extents available for the lake SSD LV"
vgs "$LAKE_VG" 2>/dev/null || echo "VG $LAKE_VG not found"
lvs 2>/dev/null || true

rule "existing LUKS mappings (expect none before the ceremony)"
if command -v cryptsetup >/dev/null 2>&1; then
  cryptsetup --version
  # dmsetup lists active device-mapper targets; grep is informational only.
  dmsetup ls --target crypt 2>/dev/null || echo "no active crypt targets"
else
  echo "cryptsetup NOT installed — install before the ceremony"
fi

rule "crypttab / fstab entries touching the targets"
grep -nE "$DATA_MOUNT|$SCRATCH_MOUNT|luks|crypt" /etc/fstab /etc/crypttab 2>/dev/null || echo "none"

rule "cryptsetup reencrypt capability (in-place path availability)"
# cryptsetup >= 2.2 supports the `reencrypt <device>` action; the cell runs 2.7.0.
# Probe the full action listing, not the short --help (the action line is only
# printed in the long help, prefixed by a tab).
if cryptsetup --help 2>&1 | grep -q 'reencrypt <device>'; then
  echo "reencrypt: available (in-place encryption is an option; NOT recommended for /data — see playbook §2)"
else
  echo "reencrypt: NOT available (evacuate+restore is the only path)"
fi

rule "done"
echo "inventory complete — no state was modified."
