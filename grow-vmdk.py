#!/usr/bin/env python3
"""
grow-vmdk.py - Safely grow a VMware virtual disk (VMDK) on a running VM, so it
can be claimed in-guest by extend-lv.sh (--mode grow).

Guard rails ("protect us from ourselves"):
  * Refuses if the VM has snapshots - vSphere blocks disk grow with snapshots
    present, so we fail early with a clear message instead of a cryptic API error.
  * Grow only, never shrink. No-op (exit 0) if the disk already meets the target.
  * Targets exactly ONE disk, selected by label ("Hard disk 2") or SCSI address
    ("0:1"). Refuses if the selector matches zero or multiple disks.
  * --dry-run reports the intended change and touches nothing.

End-to-end example (vCenter -> guest):
  python3 grow-vmdk.py --host vcenter.example.com --user svc_lvm \\
      --vm db01 --scsi 0:1 --add-gb 50
  ssh root@db01 'extend-lv.sh --mode grow --device /dev/sdb --vg vg_data --lv lv_data'

Requires: pip install pyvmomi
Password: --password, env VC_PASSWORD, or interactive prompt.
"""
import argparse
import getpass
import os
import ssl
import sys
import time

try:
    from pyVim.connect import SmartConnect, Disconnect
    from pyVmomi import vim
except ImportError:
    sys.exit("pyvmomi is required: pip install pyvmomi")

GB_IN_KB = 1024 * 1024


def parse_args():
    p = argparse.ArgumentParser(description="Safely grow a VMDK on a running VM.")
    p.add_argument("--host", required=True, help="vCenter / ESXi hostname")
    p.add_argument("--user", required=True, help="vCenter username")
    p.add_argument("--password", default=os.environ.get("VC_PASSWORD"))
    p.add_argument("--port", type=int, default=443)
    p.add_argument("--vm", required=True, help="VM name (must be unique)")
    sel = p.add_mutually_exclusive_group(required=True)
    sel.add_argument("--disk-label", help='e.g. "Hard disk 2"')
    sel.add_argument("--scsi", help='SCSI address controllerBus:unit, e.g. "0:1"')
    size = p.add_mutually_exclusive_group(required=True)
    size.add_argument("--add-gb", type=int, help="grow by this many GB")
    size.add_argument("--new-size-gb", type=int, help="grow to this total size in GB")
    p.add_argument("--insecure", action="store_true", help="skip TLS verification")
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def find_vm(content, name):
    view = content.viewManager.CreateContainerView(
        content.rootFolder, [vim.VirtualMachine], True)
    matches = [vm for vm in view.view if vm.name == name]
    view.Destroy()
    if not matches:
        sys.exit(f"ERROR: no VM named '{name}' found")
    if len(matches) > 1:
        sys.exit(f"ERROR: {len(matches)} VMs named '{name}' - selector is ambiguous")
    return matches[0]


def scsi_address(vm, disk):
    """Return 'bus:unit' for a VirtualDisk, or None if not on a SCSI controller."""
    ctrl = next((d for d in vm.config.hardware.device
                 if d.key == disk.controllerKey), None)
    if isinstance(ctrl, vim.vm.device.VirtualSCSIController):
        return f"{ctrl.busNumber}:{disk.unitNumber}"
    return None


def select_disk(vm, args):
    disks = [d for d in vm.config.hardware.device
             if isinstance(d, vim.vm.device.VirtualDisk)]
    if args.disk_label:
        hits = [d for d in disks if d.deviceInfo.label == args.disk_label]
    else:
        hits = [d for d in disks if scsi_address(vm, d) == args.scsi]
    if not hits:
        sys.exit(f"ERROR: no disk matched selector "
                 f"({args.disk_label or args.scsi})")
    if len(hits) > 1:
        sys.exit("ERROR: selector matched multiple disks - refine it")
    return hits[0]


def wait_for_task(task):
    while task.info.state in (vim.TaskInfo.State.queued,
                              vim.TaskInfo.State.running):
        time.sleep(1)
    if task.info.state != vim.TaskInfo.State.success:
        msg = getattr(task.info.error, "msg", task.info.error)
        sys.exit(f"ERROR: ReconfigVM_Task failed: {msg}")


def main():
    args = parse_args()
    pwd = args.password or getpass.getpass(f"Password for {args.user}@{args.host}: ")

    ctx = ssl._create_unverified_context() if args.insecure else None
    try:
        si = SmartConnect(host=args.host, user=args.user, pwd=pwd,
                          port=args.port, sslContext=ctx)
    except Exception as exc:  # noqa: BLE001
        sys.exit(f"ERROR: cannot connect to vCenter: {exc}")

    try:
        vm = find_vm(si.RetrieveContent(), args.vm)

        # SAFETY: snapshots block a disk grow.
        if vm.snapshot is not None:
            sys.exit(f"SAFETY: VM '{vm.name}' has snapshots. Consolidate/remove "
                     "them before growing a disk.")

        disk = select_disk(vm, args)
        cur_kb = disk.capacityInKB
        addr = scsi_address(vm, disk) or "n/a"

        if args.new_size_gb is not None:
            new_kb = args.new_size_gb * GB_IN_KB
        else:
            new_kb = cur_kb + args.add_gb * GB_IN_KB

        label = disk.deviceInfo.label
        print(f"VM '{vm.name}'  disk '{label}'  SCSI {addr}  "
              f"power={vm.runtime.powerState}")
        print(f"current: {cur_kb / GB_IN_KB:.1f} GB  ->  target: {new_kb / GB_IN_KB:.1f} GB")

        # SAFETY: grow only, never shrink; no-op if already big enough.
        if new_kb <= cur_kb:
            print("Disk already meets or exceeds the target size - nothing to do.")
            return

        if args.dry_run:
            print("[dry-run] would issue ReconfigVM_Task to grow the disk.")
            return

        disk.capacityInKB = new_kb
        change = vim.vm.device.VirtualDeviceConfigSpec(
            operation=vim.vm.device.VirtualDeviceConfigSpec.Operation.edit,
            device=disk)
        spec = vim.vm.ConfigSpec(deviceChange=[change])
        print("Reconfiguring VM to grow the disk...")
        wait_for_task(vm.ReconfigVM_Task(spec=spec))
        print("VMDK grown. Now rescan + extend inside the guest, e.g.:")
        print("  extend-lv.sh --mode grow --device /dev/sdX --vg <vg> --lv <lv>")
    finally:
        Disconnect(si)


if __name__ == "__main__":
    main()
