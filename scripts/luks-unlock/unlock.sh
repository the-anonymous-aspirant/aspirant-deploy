#!/usr/bin/env bash
#
# unlock.sh — repeatable post-boot remote unlock for the data-lake LUKS volumes.
#
# Task #4132 (#4120-B), child B of the 0b encryption epic #4120. Turns the
# one-time post-boot unlock proof from the #4131 layer-1 ceremony into a durable,
# idempotent, operator-run recovery command.
#
# DESIGN STANCE (see LUKS_LAYER1_PLAYBOOK.md §3, DATA_LAKE_DESIGN.md §11.2):
#   None of these volumes is the OS root `/`, so the cell boots to a fully
#   networked SSH login without any unlock — `dropbear-initramfs` is NOT needed.
#   Remote unlock is simply: SSH into the running cell over the real network and
#   run this script. It `cryptsetup luksOpen`s each container (prompting for the
#   passphrase, which is never stored on the box), mounts it, and — only when
#   asked — brings the /data-dependent stack up. Idempotent: already-open or
#   already-mounted volumes are left alone, so a retry after a flaky SSH link is
#   always safe.
#
# Usage:
#   sudo ./unlock.sh                 # unlock + mount all three volumes
#   sudo ./unlock.sh scratch lake    # unlock + mount a subset (by short name)
#   sudo ./unlock.sh --status        # report state only, make no changes
#   sudo ./unlock.sh --start-stack   # after unlock, run "$STACK_UP_CMD" to bring
#                                     # the data-dependent services up (default:
#                                     # print the command instead of running it)
#
# The reboot drill (§11.2, operator-invoked over the degraded Wi-Fi link) is the
# real-volume acceptance test for this script; see POST_BOOT_UNLOCK_PLAYBOOK.md.
set -euo pipefail

# name -> "backing-device:mount-point". These match the mapper names the layer-1
# ceremony creates (postcheck.sh) and the real cell layout (LUKS_LAYER1_PLAYBOOK
# §1). Overridable via env for the loopback self-test (tests/luks_unlock_loopback.sh).
: "${SCRATCH_DEV:=/dev/sda}"
: "${LAKE_DEV:=/dev/mapper/ubuntu--vg--1-lake}"
: "${DATA_DEV:=/dev/md0}"
declare -A DEV MNT
DEV=( [scratch_crypt]="$SCRATCH_DEV" [lake_crypt]="$LAKE_DEV" [data_crypt]="$DATA_DEV" )
MNT=( [scratch_crypt]=/scratch     [lake_crypt]=/lake        [data_crypt]=/data )
# Unlock order: data last, matching the ceremony (§2) — the one volume that holds
# real data is touched only after the cheap volumes have proven the path.
ORDER=(scratch_crypt lake_crypt data_crypt)

ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [WARN] %s\n' "$1"; }
die()  { printf '  [FAIL] %s\n' "$1" >&2; exit 1; }
rule() { printf '\n=== %s ===\n' "$1"; }

# --- core operations (sourced by the loopback test; keep side-effect-free of main) ---

is_open()    { cryptsetup status "$1" >/dev/null 2>&1; }
is_mounted() { mountpoint -q "$1"; }

# open_one <mapper-name> <backing-device>: idempotent luksOpen.
open_one() {
  local name="$1" dev="$2"
  if is_open "$name"; then ok "$name already unlocked"; return 0; fi
  [[ -e "$dev" ]] || die "$name: backing device $dev not present"
  cryptsetup isLuks "$dev" 2>/dev/null || die "$name: $dev is not a LUKS container (run the #4131 ceremony first)"
  cryptsetup luksOpen "$dev" "$name"   # prompts for passphrase on the controlling tty
  ok "$name unlocked from $dev"
}

# mount_one <mapper-name> <mount-point>: idempotent mount of the opened mapper.
mount_one() {
  local name="$1" mnt="$2"
  is_open "$name" || die "$name: cannot mount, mapping is not open"
  if is_mounted "$mnt"; then ok "$mnt already mounted"; return 0; fi
  mkdir -p "$mnt"
  mount "/dev/mapper/$name" "$mnt"
  ok "$mnt mounted from /dev/mapper/$name"
}

# unmount_one / close_one: teardown, used by the self-test and manual recovery.
unmount_one() { local mnt="$1"; is_mounted "$mnt" && umount "$mnt"; return 0; }
close_one()   { local name="$1"; is_open "$name" && cryptsetup luksClose "$name"; return 0; }

status_report() {
  rule "data-lake volume status"
  local name
  for name in "${ORDER[@]}"; do
    if is_open "$name"; then
      if is_mounted "${MNT[$name]}"; then ok "$name: UNLOCKED + mounted at ${MNT[$name]}"
      else warn "$name: unlocked but NOT mounted at ${MNT[$name]}"; fi
    else
      warn "$name: locked (backing ${DEV[$name]})"
    fi
  done
}

# --- main ------------------------------------------------------------------

main() {
  local status_only=no start_stack=no
  local -a want=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status)      status_only=yes; shift ;;
      --start-stack) start_stack=yes; shift ;;
      -h|--help)     sed -n '2,40p' "$0"; exit 0 ;;
      scratch|lake|data) want+=("${1}_crypt"); shift ;;
      *) die "unknown arg: $1 (expected --status, --start-stack, or scratch|lake|data)" ;;
    esac
  done

  [[ "$status_only" == yes ]] && { status_report; exit 0; }
  [[ $EUID -eq 0 ]] || die "must run as root (cryptsetup/mount) — use sudo"

  local -a targets=("${ORDER[@]}")
  [[ ${#want[@]} -gt 0 ]] && targets=("${want[@]}")

  rule "unlocking ${#targets[@]} volume(s)"
  local name
  for name in "${targets[@]}"; do
    open_one  "$name" "${DEV[$name]}"
    mount_one "$name" "${MNT[$name]}"
  done

  status_report

  if [[ "$start_stack" == yes ]]; then
    rule "bringing the data-dependent stack up"
    local cmd="${STACK_UP_CMD:-}"
    if [[ -z "$cmd" ]]; then
      warn "STACK_UP_CMD is unset — not starting anything."
      warn "Set it to your deploy bring-up, e.g.:"
      warn "  STACK_UP_CMD='docker compose -f /home/aspirant/aspirant-deploy/docker-compose.yml up -d'"
    else
      ok "running: $cmd"
      eval "$cmd"
    fi
  else
    printf '\n  Volumes ready. Bring services up with --start-stack (or your normal deploy path).\n'
  fi
}

# Only run main when executed directly; sourcing (the self-test) just defines the
# functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
