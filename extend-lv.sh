#!/usr/bin/env bash
#
# extend-lv.sh - Online LVM logical-volume extension for RHEL 8.1+
#                (also modern Debian/Ubuntu). LV + filesystem stay ONLINE.
#
# Designed for VMs: pair with grow-vmdk.py (grow the VMDK in vCenter) then run
# this in the guest. Two modes:
#   add   A new disk/LUN was presented   -> pvcreate + vgextend + grow LV/FS
#   grow  The disk backing the PV grew    -> rescan + (growpart) + pvresize + grow
#
# SAFETY ("protect us from ourselves"): the script refuses to act on a device
# that is mounted, holds an existing filesystem/RAID signature, is owned by a
# different VG, is in use as swap, or has device-mapper/md holders. It also
# verifies the VG/LV exist, that the filesystem is one we can grow online
# (xfs/ext2/3/4), backs up LVM metadata, takes a host lock to prevent concurrent
# runs, and is a safe no-op when there is nothing to grow. Override the device
# in-use refusals with --force only when you are certain.
#
set -Eeuo pipefail

PROG=${0##*/}
die()  { echo "[$PROG] ERROR: $*" >&2; exit 1; }
info() { echo "[$PROG] $*"; }
fail_check() { die "SAFETY CHECK FAILED: $* (override with --force if you are certain)"; }

# ---- defaults ----------------------------------------------------------------
MODE="" DEVICE="" VG="" LV=""
EXTEND="+100%FREE"        # +100%FREE | +50G | +25%VG
USE_PARTITION=false
NO_RESCAN=false
DRY_RUN=false
FORCE=false
RESIZE_FS=true            # set false automatically if the LV is not mounted
SKIP_GROW=false           # set true when there is nothing to grow

usage() {
  cat <<EOF
Usage: $PROG --mode <add|grow> --device <dev> --vg <vg> --lv <lv> [options]

Required:
  --mode <add|grow>   add  = new disk presented   grow = backing disk enlarged
  --device <dev>      add : new disk (/dev/sdb)    grow : PV device (/dev/sdb or /dev/sdb3)
  --vg <name>         volume group
  --lv <name>         logical volume

Options:
  --extend <spec>     LV growth amount (default +100%FREE; e.g. +50G, +25%VG)
  --partition         (add) create a GPT/LVM partition instead of whole-disk PV
  --no-rescan         skip the SCSI/device rescan
  --force             override device-in-use safety refusals (use with care)
  --dry-run           print commands; change nothing
  -h, --help          this help
EOF
}

# ---- arg parsing -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)      MODE="${2:?}"; shift 2 ;;
    --device)    DEVICE="${2:?}"; shift 2 ;;
    --vg)        VG="${2:?}"; shift 2 ;;
    --lv)        LV="${2:?}"; shift 2 ;;
    --extend)    EXTEND="${2:?}"; shift 2 ;;
    --partition) USE_PARTITION=true; shift ;;
    --no-rescan) NO_RESCAN=true; shift ;;
    --force)     FORCE=true; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
done

[[ -n $MODE && -n $DEVICE && -n $VG && -n $LV ]] || { usage; exit 2; }
[[ $MODE == add || $MODE == grow ]] || die "--mode must be add or grow"
[[ $EUID -eq 0 ]] || die "must run as root"

# concurrency guard: never let two growth runs race on the same host
if command -v flock >/dev/null 2>&1 && ! $DRY_RUN; then
  LOCKFILE="/run/extend-lv.${VG}.lock"
  exec 9>"$LOCKFILE" || die "cannot open lock file $LOCKFILE"
  flock -n 9 || die "another extend-lv run is in progress (lock: $LOCKFILE)"
fi

run() { info "+ $*"; $DRY_RUN && return 0; "$@"; }

# ---- helpers -----------------------------------------------------------------
part_suffix() { [[ $1 =~ [0-9]$ ]] && echo "p" || echo ""; }
pv_in_vg() { [[ "$(pvs --noheadings -o vg_name "$1" 2>/dev/null | tr -d '[:space:]')" == "$2" ]]; }
sigs_on()  { lsblk -nro FSTYPE "$1" 2>/dev/null | grep -v '^$' || true; }
mnts_on()  { lsblk -nro MOUNTPOINT "$1" 2>/dev/null | grep -v '^$' || true; }
holders_of() { local n; n=$(basename "$1"); ls -1 "/sys/block/$n/holders" 2>/dev/null || true; }

rescan_all_hosts() {
  info "Rescanning all SCSI hosts for newly presented disks..."
  $DRY_RUN && return 0
  for h in /sys/class/scsi_host/host*/scan; do echo "- - -" > "$h" 2>/dev/null || true; done
  udevadm settle || true
}
rescan_one_disk() {
  local name; name=$(basename "$1")
  info "Rescanning $1 to pick up its new size..."
  $DRY_RUN && return 0
  echo 1 > "/sys/class/block/${name}/device/rescan"
  udevadm settle || true
}

# ---- safety: about to INITIALISE a fresh device -----------------------------
preflight_add() {
  local dev="$DEVICE"
  [[ -b $dev ]] || die "$dev is not a block device (rescan may need more time)"
  local m; m=$(mnts_on "$dev")
  [[ -z $m ]] || { $FORCE || fail_check "$dev (or a partition) is mounted at: $(echo "$m" | tr '\n' ' ')"; }
  if grep -qE "^$(readlink -f "$dev")\b" /proc/swaps 2>/dev/null; then
    $FORCE || fail_check "$dev is in use as swap"
  fi
  local s; s=$(sigs_on "$dev")
  [[ -z $s ]] || { $FORCE || fail_check "$dev already holds data/signatures ($(echo "$s" | tr '\n' ',')); refusing to overwrite"; }
  local vg; vg=$(pvs --noheadings -o vg_name "$dev" 2>/dev/null | tr -d '[:space:]')
  [[ -z $vg ]] || { $FORCE || fail_check "$dev is already a PV in volume group '$vg'"; }
  local h; h=$(holders_of "$dev")
  [[ -z $h ]] || { $FORCE || fail_check "$dev has holders (in use by: $h)"; }
}

# ---- safety: GROW mode device must already be our PV ------------------------
preflight_grow() {
  [[ -b $DEVICE ]] || die "$DEVICE is not a block device"
  pvs --noheadings -o pv_name "$DEVICE" &>/dev/null \
    || die "SAFETY: $DEVICE is not an LVM PV - wrong device for grow mode?"
  pv_in_vg "$DEVICE" "$VG" \
    || die "SAFETY: $DEVICE is a PV but belongs to VG '$(pvs --noheadings -o vg_name "$DEVICE" | tr -d '[:space:]')', not '$VG'"
}

# ---- safety: VG/LV/filesystem checks shared by both modes -------------------
preflight_lv() {
  vgs --noheadings -o vg_name "$VG" &>/dev/null || die "volume group '$VG' does not exist"
  local lvpath="/dev/${VG}/${LV}"
  [[ -e $lvpath ]] || die "logical volume $lvpath not found"

  local fstype; fstype=$(lsblk -no FSTYPE "$lvpath" 2>/dev/null | head -1)
  case "$fstype" in
    xfs|ext2|ext3|ext4) : ;;
    "") die "SAFETY: no filesystem detected on $lvpath - refusing to auto-grow (resize it manually)" ;;
    *)  $FORCE || fail_check "filesystem '$fstype' on $lvpath is not supported for online auto-grow (xfs/ext only)" ;;
  esac

  local mnt; mnt=$(findmnt -no TARGET "$lvpath" 2>/dev/null | head -1)
  if [[ -z $mnt ]]; then
    RESIZE_FS=false
    info "WARNING: $lvpath is not mounted; the LV will be extended but the filesystem will NOT be grown."
    info "         Mount it, then run: xfs_growfs <mountpoint>   (XFS)   or   resize2fs $lvpath   (ext)"
  fi

  # No-op safety for additive %FREE growth when the VG is fully allocated
  local free_ext; free_ext=$(vgs --noheadings -o vg_free_count "$VG" 2>/dev/null | tr -d '[:space:]')
  if [[ $EXTEND == *%FREE* && ${free_ext:-0} -eq 0 ]]; then
    info "VG '$VG' has no free extents - nothing to grow. Exiting cleanly (no-op)."
    SKIP_GROW=true
  fi
}

# ---- core actions ------------------------------------------------------------
add_mode() {
  $NO_RESCAN || rescan_all_hosts
  [[ -b $DEVICE ]] || die "$DEVICE is not a block device"
  local pv_dev="$DEVICE"
  $USE_PARTITION && pv_dev="${DEVICE}$(part_suffix "$DEVICE")1"

  if pv_in_vg "$pv_dev" "$VG"; then
    info "$pv_dev is already a PV in $VG (idempotent rerun) - skipping initialisation"
  else
    preflight_add
    if $USE_PARTITION; then
      info "Creating GPT partition with LVM flag on $DEVICE..."
      run parted -s "$DEVICE" mklabel gpt
      run parted -s "$DEVICE" mkpart primary 0% 100%
      run parted -s "$DEVICE" set 1 lvm on
      $DRY_RUN || { udevadm settle; partprobe "$DEVICE" || true; }
    fi
    if pvs --noheadings -o pv_name "$pv_dev" &>/dev/null; then
      info "$pv_dev is already a PV - skipping pvcreate"
    else
      run pvcreate "$pv_dev"
    fi
    run vgextend "$VG" "$pv_dev"
  fi

  preflight_lv
  grow_lv
}

grow_mode() {
  preflight_grow
  local pv_dev="$DEVICE"
  local parent; parent=$(lsblk -ndo pkname "$pv_dev" 2>/dev/null || true)
  if [[ -n $parent ]]; then
    local disk="/dev/$parent"
    local partnum; partnum=$(cat "/sys/class/block/$(basename "$pv_dev")/partition")
    $NO_RESCAN || rescan_one_disk "$disk"
    command -v growpart >/dev/null || die "growpart not found - install cloud-utils-growpart"
    info "Growing partition $partnum on $disk..."
    run growpart "$disk" "$partnum" || info "growpart: no change (partition already maximal)"
    $DRY_RUN || { udevadm settle; partprobe "$disk" || true; }
  else
    $NO_RESCAN || rescan_one_disk "$pv_dev"
  fi
  run pvresize "$pv_dev"
  preflight_lv
  grow_lv
}

grow_lv() {
  $SKIP_GROW && return 0
  local lvpath="/dev/${VG}/${LV}"
  local flag="-L"; [[ $EXTEND == *%* ]] && flag="-l"
  local r=""; $RESIZE_FS && r="-r"

  info "Backing up LVM metadata for $VG..."
  run vgcfgbackup "$VG"

  info "Extending $lvpath by '$EXTEND'$([[ -n $r ]] && echo ' and growing its filesystem online')..."
  run lvextend $r "$flag" "$EXTEND" "$lvpath"

  info "Done. New geometry:"
  $DRY_RUN || { lvs "$VG/$LV"; df -h "$lvpath" 2>/dev/null || true; }
}

case "$MODE" in
  add)  add_mode ;;
  grow) grow_mode ;;
esac
