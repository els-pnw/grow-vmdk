#!/usr/bin/env bats
# Tests for extend-lv.sh using the bats-core framework.
# https://bats-core.readthedocs.io/
#
# Run:  bats tests/test_extend_lv.bats
#
# Strategy: we stub every external binary (lsblk, pvs, vgs, pvcreate, …) with
# tiny shell functions exported into each test's environment.  The script is
# sourced via a wrapper so we can intercept the calls without needing root or
# real block devices.
#
# All tests run as the current (non-root) user; root-check is patched via the
# EUID variable.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/extend-lv.sh"

# ---------------------------------------------------------------------------
# Helper: run the script with a fake-root environment and a full suite of
# stub binaries that simulate a clean slate unless overridden by the test.
# ---------------------------------------------------------------------------
run_script() {
  # Build a temporary directory of stub executables that this test controls.
  local stub_dir; stub_dir="$(mktemp -d)"

  # Write each stub; tests can override by writing their own into $stub_dir
  # before calling run_script, or by setting env vars that the stubs inspect.

  # flock: succeed immediately (no real locking needed)
  cat > "$stub_dir/flock" <<'SH'
#!/bin/sh
# -n flag: just succeed
shift; exec "$@" 2>/dev/null || true
SH

  # lsblk: returns nothing by default (clean device)
  cat > "$stub_dir/lsblk" <<'SH'
#!/bin/sh
# Honour STUB_LSBLK_FSTYPE / STUB_LSBLK_MOUNTPOINT / STUB_LSBLK_PKNAME
case "$*" in
  *FSTYPE*) echo "${STUB_LSBLK_FSTYPE:-}" ;;
  *MOUNTPOINT*) echo "${STUB_LSBLK_MOUNTPOINT:-}" ;;
  *pkname*) echo "${STUB_LSBLK_PKNAME:-}" ;;
  *) ;;
esac
SH

  # pvs: by default device is not a PV
  cat > "$stub_dir/pvs" <<'SH'
#!/bin/sh
case "$*" in
  *vg_name*) echo "${STUB_PVS_VG_NAME:-}" ;;
  *pv_name*) echo "${STUB_PVS_PV_NAME:-}" ;;
  *) exit "${STUB_PVS_RC:-1}" ;;
esac
SH

  # vgs: by default VG exists, 100 free extents
  cat > "$stub_dir/vgs" <<'SH'
#!/bin/sh
case "$*" in
  *vg_free_count*) echo "${STUB_VGS_FREE:-100}" ;;
  *vg_name*) echo "${STUB_VGS_NAME:-vg_data}" ;;
  *) exit "${STUB_VGS_RC:-0}" ;;
esac
SH

  # pvcreate, vgextend, pvresize, vgcfgbackup: succeed silently
  for cmd in pvcreate vgextend pvresize vgcfgbackup parted partprobe udevadm; do
    printf '#!/bin/sh\nexit ${STUB_%s_RC:-0}\n' "$(echo "$cmd" | tr '[:lower:]' '[:upper:]')" \
      > "$stub_dir/$cmd"
  done

  # lvextend: succeed silently
  cat > "$stub_dir/lvextend" <<'SH'
#!/bin/sh
exit ${STUB_LVEXTEND_RC:-0}
SH

  # lvs / df: report something harmless
  cat > "$stub_dir/lvs" <<'SH'
#!/bin/sh
echo "  lv_data vg_data -wi-ao---- 150.00g"
SH
  cat > "$stub_dir/df" <<'SH'
#!/bin/sh
echo "Filesystem      Size  Used Avail Use% Mounted on"
echo "/dev/vg_data/lv_data  150G   10G  140G   7% /data"
SH

  # findmnt: mounted by default (so FS resize runs)
  cat > "$stub_dir/findmnt" <<'SH'
#!/bin/sh
echo "${STUB_FINDMNT_TARGET:-/data}"
SH

  # growpart: succeed
  cat > "$stub_dir/growpart" <<'SH'
#!/bin/sh
exit ${STUB_GROWPART_RC:-0}
SH

  # scsi_host scan / block rescan: dev files we can't create, so stub echo
  # (the script uses direct file writes; those are skipped in dry-run mode)

  chmod +x "$stub_dir"/*

  # Pass a fake block device path that "exists" as a regular file so -b
  # checks need shimming too.  We override the -b test via a wrapper file.
  cat > "$stub_dir/_wrapper.sh" <<WRAPPER
#!/usr/bin/env bash
# Inject stubs into PATH, fake EUID=0, and source the real script.
export PATH="$stub_dir:\$PATH"
export EUID=0

# Fake block device check: treat STUB_BLOCK_DEVICE as a block device
_orig_test=\$(type -p test 2>/dev/null || echo test)
test() {
  if [[ "\$1" == "-b" ]]; then
    [[ "\$2" == "\${STUB_BLOCK_DEVICE:-/dev/sdb}" ]] && return 0
    return 1
  fi
  command test "\$@"
}
export -f test

# Fake /proc/swaps check
PROC_SWAPS="\${STUB_PROC_SWAPS:-}"
grep() {
  if [[ "\$*" == *"/proc/swaps"* ]]; then
    [[ -n "\$PROC_SWAPS" ]] && echo "\$PROC_SWAPS" | command grep "\$@" && return 0
    return 1
  fi
  command grep "\$@"
}
export -f grep

# Fake /sys holders
ls() {
  if [[ "\$*" == */holders* ]]; then
    echo "\${STUB_HOLDERS:-}"
    return 0
  fi
  command ls "\$@"
}
export -f ls

# Fake readlink
readlink() {
  echo "\${2:-/dev/sdb}"
}
export -f readlink

source "$SCRIPT" "\$@"
WRAPPER
  chmod +x "$stub_dir/_wrapper.sh"

  # Export all STUB_* vars so they're visible to subshells
  export STUB_BLOCK_DEVICE="${STUB_BLOCK_DEVICE:-/dev/sdb}"

  run bash "$stub_dir/_wrapper.sh" "$@"
  rm -rf "$stub_dir"
}

# ---------------------------------------------------------------------------
# Basic argument validation
# ---------------------------------------------------------------------------

@test "missing required args prints usage and exits 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "--help exits 0" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown argument exits with error" {
  run bash "$SCRIPT" --mode grow --device /dev/sdb --vg vg_data --lv lv_data --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown argument"* ]]
}

@test "invalid mode exits with error" {
  run bash "$SCRIPT" --mode bad --device /dev/sdb --vg vg_data --lv lv_data
  [ "$status" -ne 0 ]
  [[ "$output" == *"add or grow"* ]]
}

# ---------------------------------------------------------------------------
# grow mode — happy path (dry-run so no real disk ops)
# ---------------------------------------------------------------------------

@test "grow mode dry-run succeeds for valid PV" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME="vg_data"
  export STUB_PVS_PV_NAME="/dev/sdb"
  export STUB_PVS_RC=0
  export STUB_LSBLK_FSTYPE="xfs"
  export STUB_LSBLK_MOUNTPOINT="/data"
  export STUB_LSBLK_PKNAME=""

  run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -eq 0 ]
}

@test "grow mode dry-run shows pvresize command" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME="vg_data"
  export STUB_PVS_PV_NAME="/dev/sdb"
  export STUB_PVS_RC=0
  export STUB_LSBLK_FSTYPE="xfs"
  export STUB_LSBLK_MOUNTPOINT="/data"
  export STUB_LSBLK_PKNAME=""

  run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [[ "$output" == *"pvresize"* ]]
}

@test "grow mode exits if device is not a PV" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_RC=1

  run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"not an LVM PV"* ]]
}

@test "grow mode exits if PV belongs to different VG" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_RC=0
  export STUB_PVS_VG_NAME="vg_other"

  run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"belongs to VG"* ]]
}

# ---------------------------------------------------------------------------
# add mode — happy path (dry-run)
# ---------------------------------------------------------------------------

@test "add mode dry-run succeeds for a clean device" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME=""
  export STUB_PVS_RC=1
  export STUB_LSBLK_FSTYPE=""
  export STUB_LSBLK_MOUNTPOINT=""
  export STUB_LSBLK_FSTYPE=""

  run_script --mode add --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -eq 0 ]
}

@test "add mode dry-run shows pvcreate command" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME=""
  export STUB_PVS_RC=1
  export STUB_LSBLK_FSTYPE=""
  export STUB_LSBLK_MOUNTPOINT=""

  run_script --mode add --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [[ "$output" == *"pvcreate"* ]]
}

# ---------------------------------------------------------------------------
# Safety: add mode refuses in-use devices
# ---------------------------------------------------------------------------

@test "add mode refuses mounted device without --force" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME=""
  export STUB_PVS_RC=1
  export STUB_LSBLK_FSTYPE=""
  export STUB_LSBLK_MOUNTPOINT="/mnt/data"

  run_script --mode add --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"SAFETY CHECK FAILED"* ]]
}

@test "add mode with --force proceeds past mounted device" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME=""
  export STUB_PVS_RC=1
  export STUB_LSBLK_FSTYPE=""
  export STUB_LSBLK_MOUNTPOINT="/mnt/data"

  run_script --mode add --device /dev/sdb --vg vg_data --lv lv_data --dry-run --force
  [ "$status" -eq 0 ]
}

@test "add mode refuses device with existing filesystem without --force" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME=""
  export STUB_PVS_RC=1
  export STUB_LSBLK_FSTYPE="ext4"
  export STUB_LSBLK_MOUNTPOINT=""

  run_script --mode add --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"SAFETY CHECK FAILED"* ]]
}

@test "add mode refuses device with dm/md holders without --force" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME=""
  export STUB_PVS_RC=1
  export STUB_LSBLK_FSTYPE=""
  export STUB_LSBLK_MOUNTPOINT=""
  export STUB_HOLDERS="dm-0"

  run_script --mode add --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"SAFETY CHECK FAILED"* ]]
}

@test "add mode refuses device already in another VG without --force" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME="vg_other"
  export STUB_PVS_RC=0
  export STUB_LSBLK_FSTYPE=""
  export STUB_LSBLK_MOUNTPOINT=""

  run_script --mode add --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"SAFETY CHECK FAILED"* ]]
}

# ---------------------------------------------------------------------------
# Safety: filesystem type checks
# ---------------------------------------------------------------------------

@test "preflight_lv refuses unsupported filesystem without --force" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME="vg_data"
  export STUB_PVS_RC=0
  export STUB_LSBLK_FSTYPE="btrfs"
  export STUB_LSBLK_MOUNTPOINT="/data"
  export STUB_LSBLK_PKNAME=""

  run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"not supported"* ]]
}

@test "preflight_lv exits when no filesystem detected" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME="vg_data"
  export STUB_PVS_RC=0
  export STUB_LSBLK_FSTYPE=""
  export STUB_LSBLK_MOUNTPOINT=""
  export STUB_FINDMNT_TARGET=""
  export STUB_LSBLK_PKNAME=""

  run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"no filesystem detected"* ]]
}

@test "supported filesystems: xfs, ext2, ext3, ext4 all pass preflight" {
  for fs in xfs ext2 ext3 ext4; do
    export STUB_BLOCK_DEVICE="/dev/sdb"
    export STUB_PVS_VG_NAME="vg_data"
    export STUB_PVS_RC=0
    export STUB_LSBLK_FSTYPE="$fs"
    export STUB_LSBLK_MOUNTPOINT="/data"
    export STUB_LSBLK_PKNAME=""

    run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run
    [ "$status" -eq 0 ] || { echo "FAILED for fs=$fs: $output"; false; }
  done
}

# ---------------------------------------------------------------------------
# No-op: VG has no free extents with %FREE extend
# ---------------------------------------------------------------------------

@test "no-op when VG has zero free extents" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME="vg_data"
  export STUB_PVS_RC=0
  export STUB_LSBLK_FSTYPE="xfs"
  export STUB_LSBLK_MOUNTPOINT="/data"
  export STUB_LSBLK_PKNAME=""
  export STUB_VGS_FREE=0

  run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"no free extents"* ]]
}

# ---------------------------------------------------------------------------
# Unmounted LV: FS resize skipped, LV still extended
# ---------------------------------------------------------------------------

@test "unmounted LV: warns that FS will not be resized" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME="vg_data"
  export STUB_PVS_RC=0
  export STUB_LSBLK_FSTYPE="xfs"
  export STUB_LSBLK_MOUNTPOINT=""
  export STUB_FINDMNT_TARGET=""
  export STUB_LSBLK_PKNAME=""

  run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"not mounted"* ]]
}

# ---------------------------------------------------------------------------
# add mode: --partition flag triggers parted commands
# ---------------------------------------------------------------------------

@test "add --partition dry-run shows parted command" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME=""
  export STUB_PVS_RC=1
  export STUB_LSBLK_FSTYPE=""
  export STUB_LSBLK_MOUNTPOINT=""

  run_script --mode add --device /dev/sdb --vg vg_data --lv lv_data \
             --partition --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"parted"* ]]
}

# ---------------------------------------------------------------------------
# add mode: idempotent - already in VG, skips init
# ---------------------------------------------------------------------------

@test "add mode is idempotent when PV already in target VG" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME="vg_data"
  export STUB_PVS_RC=0
  export STUB_LSBLK_FSTYPE="xfs"
  export STUB_LSBLK_MOUNTPOINT="/data"

  run_script --mode add --device /dev/sdb --vg vg_data --lv lv_data --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"idempotent"* ]]
}

# ---------------------------------------------------------------------------
# --no-rescan flag
# ---------------------------------------------------------------------------

@test "grow mode --no-rescan skips rescan message" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME="vg_data"
  export STUB_PVS_RC=0
  export STUB_LSBLK_FSTYPE="xfs"
  export STUB_LSBLK_MOUNTPOINT="/data"
  export STUB_LSBLK_PKNAME=""

  run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data \
             --no-rescan --dry-run
  [[ "$output" != *"Rescanning"* ]]
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# --extend flag wires through to lvextend
# ---------------------------------------------------------------------------

@test "grow mode --extend +50G shows +50G in lvextend call" {
  export STUB_BLOCK_DEVICE="/dev/sdb"
  export STUB_PVS_VG_NAME="vg_data"
  export STUB_PVS_RC=0
  export STUB_LSBLK_FSTYPE="xfs"
  export STUB_LSBLK_MOUNTPOINT="/data"
  export STUB_LSBLK_PKNAME=""

  run_script --mode grow --device /dev/sdb --vg vg_data --lv lv_data \
             --extend +50G --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"+50G"* ]]
}
