#!/usr/bin/env bash
#
# postcheck.sh — post-reboot verification for the LUKS layer-1 ceremony.
#
# Run AFTER the operator has rebooted, unlocked the volumes over SSH, and the
# services are back. Confirms each target is LUKS-mapped, mounted at its path,
# and (for /data) that the data survived intact vs a pre-reboot checksum.
#
# Usage:
#   sudo ./postcheck.sh                       # verify mapping + mount only
#   sudo ./postcheck.sh --checksum <manifest> # also diff against a pre-reboot
#                                               # checksum manifest of /data
set -euo pipefail

MANIFEST=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --checksum) MANIFEST="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# name -> expected mount point
declare -A TARGETS=(
  [scratch_crypt]=/scratch
  [lake_crypt]=/lake
  [data_crypt]=/data
)

rc=0
pass() { printf '  [PASS] %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; rc=1; }

echo "=== LUKS mapping + mount verification ==="
for name in "${!TARGETS[@]}"; do
  mnt="${TARGETS[$name]}"
  if cryptsetup status "$name" >/dev/null 2>&1; then
    pass "$name is an active LUKS mapping"
  else
    fail "$name is NOT active (expected LUKS-mapped at $mnt)"
    continue
  fi
  if mountpoint -q "$mnt" && findmnt -no SOURCE "$mnt" | grep -q "$name"; then
    pass "$mnt is mounted from /dev/mapper/$name"
  else
    fail "$mnt is not mounted from /dev/mapper/$name"
  fi
done

# Data integrity: compare current /data checksums against a manifest captured
# before the migration. Generate the manifest pre-reboot with:
#   find /data -type f -print0 | sort -z | xargs -0 sha256sum > /root/data.pre.sha256
if [[ -n "$MANIFEST" ]]; then
  echo "=== /data integrity vs $MANIFEST ==="
  if [[ ! -f "$MANIFEST" ]]; then
    fail "manifest not found: $MANIFEST"
  elif sha256sum -c "$MANIFEST" --quiet; then
    pass "/data checksums match the pre-reboot manifest — data intact"
  else
    fail "/data checksum mismatch — investigate before declaring the task done"
  fi
fi

echo "=== summary ==="
if [[ "$rc" -eq 0 ]]; then
  echo "  all layer-1 volumes verified LUKS-active and mounted."
else
  echo "  one or more checks FAILED — do not close #4131 until resolved."
fi
exit "$rc"
