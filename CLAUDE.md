# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

A two-part toolset for growing storage on running VMs:

1. **`grow-vmdk.py`** — Python script that connects to vCenter/ESXi via the vSphere API and enlarges a VMDK disk.
2. **`extend-lv.sh`** — Bash script run inside the guest OS to extend an LVM logical volume and its filesystem online.
3. **`extend-lv.yml`** — Ansible playbook equivalent of `extend-lv.sh` for fleet-scale use.
4. **`.gitlab-ci.yml`** — CI pipeline that lints/syntax-checks the playbook; the deploy job is `manual` only.

## Running the tools

### grow-vmdk.py

Requires Python 3 and pyvmomi:
```bash
pip install pyvmomi
```

```bash
# Grow by adding GB (dry-run first)
python3 grow-vmdk.py --host vcenter.example.com --user svc_lvm \
    --vm db01 --scsi 0:1 --add-gb 50 --dry-run

# Grow to an absolute size; password from env
VC_PASSWORD=secret python3 grow-vmdk.py --host vcenter.example.com --user svc_lvm \
    --vm db01 --disk-label "Hard disk 2" --new-size-gb 200
```

### extend-lv.sh

Must run as root on the guest. Requires `lvm2`, `xfsprogs` or `e2fsprogs`, and `cloud-utils-growpart` (grow mode with partitioned PV only).

```bash
# grow mode: the VMDK behind an existing PV was enlarged by grow-vmdk.py
extend-lv.sh --mode grow --device /dev/sdb --vg vg_data --lv lv_data

# add mode: a brand-new disk was presented to the VM
extend-lv.sh --mode add --device /dev/sdc --vg vg_data --lv lv_data

# dry-run (prints commands, changes nothing)
extend-lv.sh --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run
```

### extend-lv.yml (Ansible)

```bash
ansible-galaxy collection install community.general

# add mode
ansible-playbook extend-lv.yml -i inventory.ini -l db01 \
  -e "mode=add new_device=/dev/sdb vg_name=vg_data lv_name=lv_data"

# grow mode
ansible-playbook extend-lv.yml -i inventory.ini -l db01 \
  -e "mode=grow new_device=/dev/sdb vg_name=vg_data lv_name=lv_data"

# syntax check only
ansible-playbook extend-lv.yml --syntax-check
```

## Architecture: two-step disk growth

The intended workflow is always:

1. **`grow-vmdk.py`** — vCenter API call enlarges the VMDK (vSphere layer). The guest OS cannot see the new size yet.
2. **`extend-lv.sh` or `extend-lv.yml`** — Rescan/growpart makes the kernel see the new size, then `pvresize` + `lvextend -r` extends the LV and filesystem online without downtime.

The scripts are designed to be safe no-ops when there is nothing to do (e.g., disk already at target size, VG has no free extents) so they can be re-run idempotently.

## Safety guard-rails

All three tools share the same philosophy — fail early with a clear message rather than letting vSphere or LVM give a cryptic error:

- **`grow-vmdk.py`**: refuses if the VM has snapshots; refuses to shrink a disk; refuses if the disk selector is ambiguous.
- **`extend-lv.sh`** (add mode): refuses to `pvcreate` a device that is mounted, already has a filesystem/RAID signature, belongs to another VG, or has device-mapper/md holders. `--force` overrides these checks.
- Both tools support `--dry-run` to preview changes without touching anything.
- `extend-lv.sh` takes a per-VG flock so concurrent runs on the same host are blocked.
- LVM metadata is backed up (`vgcfgbackup`) before any grow operation.

## CI/CD (GitLab)

- `validate` stage: `yamllint` + `ansible-lint` + `--syntax-check` run on every push.
- `deploy` stage: **manual trigger only**, targeting `main` branch. Pipeline variables `TARGET`, `MODE`, `DEVICE`, `VG`, `LV`, `LV_SIZE` must be supplied at trigger time.
- CI variables `ANSIBLE_VAULT_PASSWORD` and `SSH_PRIVATE_KEY` should be set as masked GitLab CI/CD variables.
