#!/usr/bin/env bash
#
# preflight.sh — readiness gate for the LUKS layer-1 ceremony (#4131 / #4120-A).
#
# DESIGN STANCE: this script does the *safe* half of the ceremony — it verifies
# the box is ready and prints the exact destructive command sequence — but it
# does NOT run luksFormat / mkfs / lvcreate itself unless the operator passes
# --confirm together with the typed volume name. A layer-1 migration of a 1.8T
# production RAID is delicate enough that the destructive commands are meant to
# be read and run deliberately by the operator, not fired by a default flag.
#
# Usage:
#   sudo ./preflight.sh                     # dry-run: checks + prints commands
#   sudo ./preflight.sh --confirm scratch   # execute the /scratch path only
#   sudo ./preflight.sh --confirm lake      # execute the new lake SSD LV only
#   sudo ./preflight.sh --confirm data      # execute the /data evacuate/restore
#                                             (prompts again — this destroys /data)
set -euo pipefail

CONFIRM=""
TARGET=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --confirm) CONFIRM=yes; TARGET="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

LAKE_VG=ubuntu-vg-1
LAKE_LV=lake
LAKE_SIZE=120G           # carve from the ~130G VFree on the SSD (sdd); leave headroom
SCRATCH_DEV=/dev/sda
BACKUP_ROOT="${BACKUP_ROOT:-/data/aspirant/backups}"

ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
die()  { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }
rule() { printf '\n=== %s ===\n' "$1"; }

# --------------------------------------------------------------------------
# Readiness checks — always run, never destructive.
# --------------------------------------------------------------------------
rule "readiness checks (non-destructive)"

command -v cryptsetup >/dev/null 2>&1 || die "cryptsetup not installed"
ok "cryptsetup present: $(cryptsetup --version)"

# RAID must be clean before we touch /data.
if grep -q '\[UU\]' /proc/mdstat 2>/dev/null; then
  ok "md0 RAID1 is clean [UU]"
else
  warn "md0 not reporting [UU] — resolve RAID health BEFORE encrypting /data"
fi

# Free extents for the lake LV.
VFREE=$(vgs --noheadings -o vg_free --units g "$LAKE_VG" 2>/dev/null | tr -dc '0-9.' || echo 0)
if awk "BEGIN{exit !($VFREE+0 >= 120)}"; then
  ok "VG $LAKE_VG has ${VFREE}G free — enough for a ${LAKE_SIZE} lake LV"
else
  warn "VG $LAKE_VG free=${VFREE}G — not enough for ${LAKE_SIZE}; adjust LAKE_SIZE"
fi

# Backup presence for the one volume that carries real data.
if [[ -d "$BACKUP_ROOT" ]]; then
  ok "backup root exists: $BACKUP_ROOT"
  if command -v restic >/dev/null 2>&1; then
    ok "restic present — run 'restic check' + a test restore before proceeding"
  else
    warn "restic not on PATH — verify the /data backup path manually before /data"
  fi
else
  warn "no backup root at $BACKUP_ROOT — /data MUST be backed up before encryption"
fi

# --------------------------------------------------------------------------
# Print the destructive command sequences (always shown for review).
# --------------------------------------------------------------------------
rule "destructive command sequence (review before running)"
cat <<'PLAN'
# --- /scratch (sda, synthetic-only; correct disposal is destroy) ------------
umount /scratch
cryptsetup luksFormat /dev/sda
cryptsetup luksOpen  /dev/sda scratch_crypt
mkfs.ext4 /dev/mapper/scratch_crypt
mount /dev/mapper/scratch_crypt /scratch
# then re-seed lake-skeleton fixtures as needed

# --- lake SSD LV (new; carve from ubuntu-vg-1 free extents on the SSD) -------
lvcreate -L 120G -n lake ubuntu-vg-1
cryptsetup luksFormat /dev/ubuntu-vg-1/lake
cryptsetup luksOpen  /dev/ubuntu-vg-1/lake lake_crypt
mkfs.ext4 /dev/mapper/lake_crypt
mkdir -p /lake && mount /dev/mapper/lake_crypt /lake

# --- /data (md0 RAID1, 125G REAL data) — evacuate -> luksFormat -> restore ---
#   1. stop every service that mounts /data (compose down for the stack)
#   2. restic backup /data && restic check   # verified restorable copy
#   3. umount /data
#   4. cryptsetup luksFormat /dev/md0
#   5. cryptsetup luksOpen  /dev/md0 data_crypt
#   6. mkfs.ext4 /dev/mapper/data_crypt
#   7. mount /dev/mapper/data_crypt /data
#   8. restic restore latest --target /data && checksum-verify
#   9. bring the stack back up
# (in-place `cryptsetup reencrypt --encrypt --reduce-device-size 32M /dev/md0`
#  is technically available on 2.7.0 but NOT recommended for the 16y HDD RAID:
#  a multi-hour in-place rewrite with no verified-restorable fallback is the
#  wrong risk trade for real data — see the playbook.)
PLAN

# --------------------------------------------------------------------------
# Execution — only with --confirm <target>, and /data prompts a second time.
# --------------------------------------------------------------------------
if [[ "$CONFIRM" != "yes" ]]; then
  rule "dry-run complete"
  echo "  no destructive action taken. Re-run with --confirm <scratch|lake|data>."
  exit 0
fi

case "$TARGET" in
  scratch)
    umount /scratch
    cryptsetup luksFormat "$SCRATCH_DEV"
    cryptsetup luksOpen "$SCRATCH_DEV" scratch_crypt
    mkfs.ext4 /dev/mapper/scratch_crypt
    mount /dev/mapper/scratch_crypt /scratch
    ok "/scratch is now LUKS-backed"
    ;;
  lake)
    lvcreate -L "$LAKE_SIZE" -n "$LAKE_LV" "$LAKE_VG"
    cryptsetup luksFormat "/dev/$LAKE_VG/$LAKE_LV"
    cryptsetup luksOpen "/dev/$LAKE_VG/$LAKE_LV" lake_crypt
    mkfs.ext4 /dev/mapper/lake_crypt
    mkdir -p /lake && mount /dev/mapper/lake_crypt /lake
    ok "lake SSD LV is now LUKS-backed at /lake"
    ;;
  data)
    echo "  /data carries 125G of REAL production data across the 16y RAID."
    read -r -p "  Type exactly 'ENCRYPT /data' to proceed: " reply
    [[ "$reply" == "ENCRYPT /data" ]] || die "confirmation phrase not matched — aborting"
    die "operator must run the /data evacuate->restore steps by hand (see printed plan); \
this script refuses to automate a 1.8T restore without an interactive verified-restore checkpoint."
    ;;
  *) die "unknown --confirm target: '$TARGET' (want scratch|lake|data)" ;;
esac
