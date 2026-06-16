# grow-vmdk

A two-part toolset for growing storage on running VMware VMs — no downtime, no
filesystem unmounts, no guest reboots required.

| Tool | Where it runs | What it does |
|---|---|---|
| `grow-vmdk.py` | Your workstation / jump host | Enlarges a VMDK via the vSphere API |
| `extend-lv.sh` | Inside the guest VM (as root) | Extends the LVM LV + live filesystem |
| `extend-lv.yml` | Ansible control node | Ansible equivalent of `extend-lv.sh` |

---

## Table of contents

1. [How it works](#how-it-works)
2. [Requirements](#requirements)
3. [Quick start](#quick-start)
4. [grow-vmdk.py reference](#grow-vmdkpy-reference)
5. [extend-lv.sh reference](#extend-lvsh-reference)
6. [extend-lv.yml (Ansible) reference](#extend-lvyml-ansible-reference)
7. [Safety guard-rails](#safety-guard-rails)
8. [Testing](#testing)
9. [CI/CD](#cicd)
10. [Troubleshooting](#troubleshooting)

---

## How it works

Disk growth is always a two-step process:

```
┌─────────────────────────────────┐     ┌──────────────────────────────────┐
│  Step 1 — vSphere layer         │     │  Step 2 — Guest OS layer         │
│                                 │     │                                  │
│  grow-vmdk.py                   │────▶│  extend-lv.sh   (or the Ansible  │
│  • Connects to vCenter/ESXi     │     │  playbook)                       │
│  • Enlarges the VMDK on disk    │     │  • Rescans SCSI / growpart       │
│  • Guest cannot see new size    │     │  • pvresize / pvcreate           │
│    until the guest rescans      │     │  • lvextend -r (FS grows live)   │
└─────────────────────────────────┘     └──────────────────────────────────┘
```

Both tools support `--dry-run` so you can preview every action before anything
is changed.

---

## Requirements

### grow-vmdk.py

- Python 3.8+
- [`pyvmomi`](https://github.com/vmware/pyvmomi): `pip install pyvmomi`
- Network access to vCenter (port 443) or ESXi host

### extend-lv.sh

- RHEL 8.1+ or modern Debian/Ubuntu
- `lvm2` (almost always pre-installed)
- `xfsprogs` or `e2fsprogs` depending on your filesystem
- `cloud-utils-growpart` — only needed when the PV is a partition (not a
  whole-disk PV) and you are using `--mode grow`
- Must run as **root**

### extend-lv.yml (Ansible)

- Ansible 2.14+
- `community.general` collection:
  ```bash
  ansible-galaxy collection install community.general
  ```
- Same guest OS packages as `extend-lv.sh`

### Tests & linting (development)

Dependencies are declared in `pyproject.toml` and locked in `poetry.lock`.
The virtualenv is managed by **uv** (fast installer) and **Poetry** (dependency
resolver + lockfile).

```bash
# Install uv (if not already installed)
curl -LsSf https://astral.sh/uv/install.sh | sh

# Install Poetry (if not already installed)
curl -sSL https://install.python-poetry.org | python3 -

# Create .venv and install all deps in one step
make venv
```

- Bash tests require [bats-core](https://bats-core.readthedocs.io/):
  `brew install bats-core` (macOS) or follow the Linux install guide
- Shell linting requires
  [ShellCheck](https://www.shellcheck.net/):
  `brew install shellcheck` (macOS) or `apt install shellcheck`

---

## Quick start

### Grow a disk (most common workflow)

```bash
# 1. Enlarge the VMDK by 50 GB in vCenter (dry-run first)
python3 grow-vmdk.py \
    --host vcenter.example.com \
    --user svc_lvm \
    --vm db01 \
    --scsi 0:1 \
    --add-gb 50 \
    --dry-run

# 2. Run for real
python3 grow-vmdk.py \
    --host vcenter.example.com \
    --user svc_lvm \
    --vm db01 \
    --scsi 0:1 \
    --add-gb 50

# 3. Inside the guest, extend the LV + filesystem online
ssh root@db01 'extend-lv.sh \
    --mode grow \
    --device /dev/sdb \
    --vg vg_data \
    --lv lv_data'
```

### Add a brand-new disk

```bash
# 1. Present a new disk to the VM via vCenter (manual step in the UI or API)

# 2. Inside the guest, initialise the new disk and extend the VG/LV
extend-lv.sh \
    --mode add \
    --device /dev/sdc \
    --vg vg_data \
    --lv lv_data
```

---

## grow-vmdk.py reference

```
python3 grow-vmdk.py --host HOST --user USER --vm VM --<selector> --<size> [options]
```

### Required flags

| Flag | Description |
|---|---|
| `--host HOST` | vCenter or ESXi hostname / IP |
| `--user USER` | vSphere username (e.g. `administrator@vsphere.local`) |
| `--vm VM` | VM name (must be unique in the inventory) |

### Disk selector (pick one)

| Flag | Description |
|---|---|
| `--disk-label LABEL` | Human-readable disk label, e.g. `"Hard disk 2"` |
| `--scsi BUS:UNIT` | SCSI controller:unit address, e.g. `0:1` |

### Size (pick one)

| Flag | Description |
|---|---|
| `--add-gb N` | Grow by N gigabytes |
| `--new-size-gb N` | Grow to exactly N gigabytes total |

If the disk already meets or exceeds the requested size the script exits
cleanly — it never shrinks a disk.

### Optional flags

| Flag | Default | Description |
|---|---|---|
| `--password PWD` | env `VC_PASSWORD` or interactive prompt | vSphere password |
| `--port PORT` | `443` | vCenter HTTPS port |
| `--insecure` | off | Skip TLS certificate verification |
| `--dry-run` | off | Print the planned change; touch nothing |

### Password handling

The password is resolved in this order:
1. `--password` CLI flag
2. `VC_PASSWORD` environment variable
3. Interactive prompt (hidden input)

```bash
# Via environment variable (recommended for automation)
export VC_PASSWORD="$(vault kv get -field=password secret/vcenter)"
python3 grow-vmdk.py --host vc --user svc_lvm --vm db01 --scsi 0:1 --add-gb 50
```

---

## extend-lv.sh reference

```
extend-lv.sh --mode <add|grow> --device <dev> --vg <vg> --lv <lv> [options]
```

### Modes

| Mode | When to use |
|---|---|
| `add` | A brand-new disk or LUN was presented to the VM |
| `grow` | The existing VMDK behind a PV was enlarged by `grow-vmdk.py` |

### Required flags

| Flag | Description |
|---|---|
| `--mode add\|grow` | Operation mode (see above) |
| `--device DEV` | Block device — whole-disk PV (`/dev/sdb`) or partition (`/dev/sdb3`) |
| `--vg NAME` | LVM volume group name |
| `--lv NAME` | LVM logical volume name |

### Optional flags

| Flag | Default | Description |
|---|---|---|
| `--extend SPEC` | `+100%FREE` | LV growth amount: `+100%FREE`, `+50G`, `+25%VG` |
| `--partition` | off | (add mode) Create a GPT partition on the disk first |
| `--no-rescan` | off | Skip the kernel SCSI/block rescan step |
| `--force` | off | Override device-in-use safety refusals |
| `--dry-run` | off | Print commands; change nothing |

### Examples

```bash
# Grow mode — disk was enlarged in vCenter, extend LV by all free space
extend-lv.sh --mode grow --device /dev/sdb --vg vg_data --lv lv_data

# Grow mode — extend by exactly 50 GB
extend-lv.sh --mode grow --device /dev/sdb --vg vg_data --lv lv_data --extend +50G

# Add mode — new disk, create whole-disk PV
extend-lv.sh --mode add --device /dev/sdc --vg vg_data --lv lv_data

# Add mode — new disk, partition it first (GPT/LVM flag)
extend-lv.sh --mode add --device /dev/sdc --vg vg_data --lv lv_data --partition

# Dry-run — print every command without running anything
extend-lv.sh --mode grow --device /dev/sdb --vg vg_data --lv lv_data --dry-run

# Partitioned PV grow (device is the partition, parent disk is auto-detected)
extend-lv.sh --mode grow --device /dev/sdb3 --vg vg_data --lv lv_data
```

### What happens in grow mode

```
1. Rescan the disk so the kernel sees the enlarged size
   echo 1 > /sys/class/block/sdb/device/rescan
   
2. If the PV is a partition (not whole-disk):
   growpart /dev/sdb 3     ← expands the partition table entry
   
3. pvresize /dev/sdb       ← tells LVM about the new PV size
4. vgcfgbackup vg_data     ← backs up LVM metadata
5. lvextend -r +100%FREE /dev/vg_data/lv_data
                           ← extends LV and resizes filesystem online
```

### What happens in add mode

```
1. Rescan all SCSI hosts so the new disk appears
2. Safety checks (see below)
3. Optional: parted mklabel gpt + mkpart (if --partition)
4. pvcreate /dev/sdc
5. vgextend vg_data /dev/sdc
6. vgcfgbackup vg_data
7. lvextend -r +100%FREE /dev/vg_data/lv_data
```

---

## extend-lv.yml (Ansible) reference

The playbook is an idempotent, fleet-scale equivalent of `extend-lv.sh`.

```bash
# Install the required collection
ansible-galaxy collection install community.general

# Add mode
ansible-playbook extend-lv.yml \
    -i inventory.ini \
    -l db01 \
    -e "mode=add new_device=/dev/sdb vg_name=vg_data lv_name=lv_data"

# Grow mode
ansible-playbook extend-lv.yml \
    -i inventory.ini \
    -l db01 \
    -e "mode=grow new_device=/dev/sdb vg_name=vg_data lv_name=vg_data"

# Check syntax only (no connection required)
ansible-playbook extend-lv.yml --syntax-check
```

### Playbook variables

| Variable | Default | Description |
|---|---|---|
| `mode` | `add` | `add` or `grow` |
| `new_device` | `/dev/sdb` | Block device path |
| `vg_name` | `vg_data` | Volume group |
| `lv_name` | `lv_data` | Logical volume |
| `lv_size` | `+100%FREE` | LV growth amount |
| `use_partition` | `false` | Create a GPT partition first (add mode) |
| `rescan` | `true` | Rescan SCSI / block device |
| `force` | `false` | Override device-in-use safety checks |
| `target_hosts` | `lvm_targets` | Host or group to target |

---

## Safety guard-rails

Both tools share the same philosophy: **fail early with a clear message rather
than letting vSphere or LVM give a cryptic error.**

### grow-vmdk.py

| Guard | Behaviour |
|---|---|
| Snapshot present | Exits — vSphere blocks disk growth while snapshots exist |
| Shrink requested | Exits — tool never shrinks a disk |
| Disk already big enough | Exits cleanly (no-op) |
| Ambiguous selector | Exits if `--disk-label` or `--scsi` matches 0 or 2+ disks |

### extend-lv.sh (add mode)

| Guard | Behaviour |
|---|---|
| Device is mounted | Refuses unless `--force` |
| Device is in use as swap | Refuses unless `--force` |
| Device has existing filesystem/RAID signature | Refuses unless `--force` |
| Device is already a PV in a different VG | Refuses unless `--force` |
| Device has dm/md holders | Refuses unless `--force` |
| VG does not exist | Hard exit |
| LV does not exist | Hard exit |
| Filesystem not xfs/ext | Refuses unless `--force` |
| No filesystem detected | Hard exit |
| VG has no free extents (with `%FREE`) | Silent no-op |

### Concurrency

`extend-lv.sh` takes a per-VG `flock` lock at `/run/extend-lv.<VG>.lock` so
that concurrent runs on the same host are blocked rather than racing.

### LVM metadata backup

`vgcfgbackup` is called before any `lvextend`, writing a timestamped copy of
the VG metadata to `/etc/lvm/backup/`.

---

## Testing

```bash
# Set up the test environment (one-time — requires uv and Poetry)
make venv

# Run all tests
make test

# Run individual test suites
make test-py         # Python unit tests for grow-vmdk.py
make test-playbook   # Playbook structure/logic tests for extend-lv.yml
make test-bats       # Shell tests for extend-lv.sh (requires bats-core)

# Linting
make lint            # shellcheck + yamllint
make lint-sh         # shellcheck only
make lint-yaml       # yamllint only

# Full CI-equivalent check (lint + all tests)
make check

# Coverage report (opens htmlcov/index.html)
make coverage
```

### Test layout

```
tests/
├── conftest.py                  # adds repo root to sys.path
├── test_grow_vmdk.py            # Python unit tests (mocks vSphere API)
├── test_extend_lv.bats          # Bats shell tests (stubs all external commands)
└── test_extend_lv_playbook.py   # Playbook structure + Jinja2 logic tests
```

#### `test_grow_vmdk.py`

All vSphere API calls are mocked with `unittest.mock`; no real vCenter is
needed. Covers:

- VM lookup (not found, ambiguous)
- Disk selection by label and SCSI address
- Snapshot safety check
- No-op when disk is already large enough
- `--add-gb` and `--new-size-gb` size calculations
- `--dry-run` suppresses the API call
- Password resolution (flag → env var → prompt)
- `Disconnect` is always called (finally block)
- `wait_for_task` polls until done and surfaces errors

#### `test_extend_lv.bats`

Every external binary (`pvs`, `vgs`, `lsblk`, `lvextend`, `pvcreate`, …) is
replaced with a tiny stub. Tests run as a non-root user (EUID is shimmed to
0). Covers:

- Argument validation (missing, unknown, invalid mode)
- `grow` mode happy path
- `add` mode happy path
- Safety refusals (mounted, swap, existing FS, wrong VG, dm holders)
- `--force` override
- Filesystem type checks (xfs/ext2/ext3/ext4 pass; btrfs/empty fail)
- No-op when VG has no free extents
- Unmounted LV warns and skips FS resize
- `--partition` triggers parted commands
- Idempotent rerun (PV already in VG)
- `--no-rescan` suppresses rescan
- `--extend` value passed through to `lvextend`

#### `test_extend_lv_playbook.py`

Loads the YAML directly without Ansible. Covers:

- Playbook parses as valid YAML
- Required variables are defined with correct defaults
- Key tasks are present and in the correct order (metadata backup before extend)
- `when:` conditions are correct on each task
- Jinja2 `pv_device` expression logic (whole-disk vs partition suffix, grow vs add)
- Assert tasks have `fail_msg` and correct expressions
- Correct modules used (`community.general.lvol`, `community.general.parted`)
- `resizefs` is gated on mount status

---

## CI/CD

The `.gitlab-ci.yml` pipeline has two stages:

### `validate` (runs on every push)

1. `yamllint` — checks YAML syntax and style
2. `ansible-lint` — checks Ansible best-practice rules
3. `ansible-playbook --syntax-check` — validates task structure

### `deploy` (manual trigger, `main` branch only)

The deploy job never runs unattended. It requires pipeline variables supplied
at trigger time:

| Variable | Example | Description |
|---|---|---|
| `TARGET` | `db01` | Ansible host or group limit |
| `MODE` | `grow` | `add` or `grow` |
| `DEVICE` | `/dev/sdb` | Block device on the target |
| `VG` | `vg_data` | Volume group |
| `LV` | `lv_data` | Logical volume |
| `LV_SIZE` | `+100%FREE` | LV growth spec |

Set these as **masked** CI/CD variables in GitLab (Settings → CI/CD →
Variables):

- `ANSIBLE_VAULT_PASSWORD` — if you encrypt inventory or secrets with Vault
- `SSH_PRIVATE_KEY` — SSH key for the deploy user on managed nodes

---

## Troubleshooting

### `pyvmomi is required`
```bash
pip install pyvmomi
```

### `no VM named 'X' found`
The VM name must match exactly as shown in vCenter. Names are case-sensitive.

### `VM has snapshots`
Consolidate or delete all snapshots before growing a disk. vSphere cannot
resize a VMDK that has a snapshot chain.

### `not a block device` (extend-lv.sh)
The SCSI rescan may need a moment. Wait a few seconds and retry, or check with
`lsblk`. In `grow` mode the device must already exist (it should, since it's
an existing PV).

### `growpart not found`
Install `cloud-utils-growpart`:
- RHEL/Rocky: `dnf install cloud-utils-growpart`
- Debian/Ubuntu: `apt install cloud-guest-utils`

Only required when the PV is a **partition** in `grow` mode (not a
whole-disk PV).

### `SAFETY CHECK FAILED: … is mounted`
Pass `--force` only if you are certain the device does not hold live data. For
the `add` mode the intent is to initialise a **blank** disk; a mounted device
is almost certainly a mistake.

### LV was extended but the filesystem did not grow
The LV was not mounted at the time `extend-lv.sh` ran. Mount it first, then
resize manually:
```bash
# XFS
xfs_growfs /mountpoint

# ext4
resize2fs /dev/vg_data/lv_data
```

### `another extend-lv run is in progress`
A previous run holds the flock lock at `/run/extend-lv.<VG>.lock`. Verify no
other process is actively resizing, then remove the stale lock file if safe:
```bash
rm /run/extend-lv.vg_data.lock
```
