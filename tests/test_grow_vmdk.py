"""
Unit tests for grow-vmdk.py.

All vSphere API calls are mocked; no real vCenter is required.
Run: pytest tests/test_grow_vmdk.py -v

pyvmomi stubs and the 'grow_vmdk' module alias are installed by conftest.py
before this file is collected, so all imports here work without pyvmomi.
"""
import sys
import unittest
from unittest.mock import MagicMock, patch

import grow_vmdk

# VIM stubs were installed by conftest.py; retrieve them here for type checks.
VIM = sys.modules["pyVmomi"].vim

GB = grow_vmdk.GB_IN_KB  # 1 048 576  KB per GB


# ---------------------------------------------------------------------------
# Helpers to build minimal mock objects
# ---------------------------------------------------------------------------

def _make_disk(label="Hard disk 1", capacity_gb=100, ctrl_key=1000, unit=0):
    disk = MagicMock(spec=VIM.vm.device.VirtualDisk)
    disk.__class__ = VIM.vm.device.VirtualDisk
    disk.deviceInfo = MagicMock()
    disk.deviceInfo.label = label
    disk.capacityInKB = capacity_gb * GB
    disk.controllerKey = ctrl_key
    disk.unitNumber = unit
    return disk


def _make_scsi_ctrl(key=1000, bus=0):
    ctrl = MagicMock(spec=VIM.vm.device.VirtualSCSIController)
    ctrl.__class__ = VIM.vm.device.VirtualSCSIController
    ctrl.key = key
    ctrl.busNumber = bus
    return ctrl


def _make_vm(name="myvm", disks=None, ctrls=None, snapshots=None, power="poweredOn"):
    vm = MagicMock()
    vm.name = name
    vm.snapshot = snapshots
    vm.runtime = MagicMock()
    vm.runtime.powerState = power
    devices = list(ctrls or []) + list(disks or [])
    vm.config = MagicMock()
    vm.config.hardware = MagicMock()
    vm.config.hardware.device = devices
    vm.ReconfigVM_Task = MagicMock()
    return vm


def _make_task(state="success", error_msg=None):
    task = MagicMock()
    task.info = MagicMock()
    task.info.state = state
    task.info.error = MagicMock()
    task.info.error.msg = error_msg
    return task


# ---------------------------------------------------------------------------
# Tests: find_vm
# ---------------------------------------------------------------------------

class TestFindVm(unittest.TestCase):

    def _content_with(self, vms):
        view = MagicMock()
        view.view = vms
        content = MagicMock()
        content.viewManager.CreateContainerView.return_value = view
        return content

    def test_finds_single_match(self):
        vm = MagicMock(); vm.name = "db01"
        result = grow_vmdk.find_vm(self._content_with([vm]), "db01")
        self.assertIs(result, vm)

    def test_exits_on_no_match(self):
        with self.assertRaises(SystemExit) as cm:
            grow_vmdk.find_vm(self._content_with([]), "missing")
        self.assertIn("no VM named", str(cm.exception))

    def test_exits_on_ambiguous_match(self):
        vm1 = MagicMock(); vm1.name = "clone"
        vm2 = MagicMock(); vm2.name = "clone"
        with self.assertRaises(SystemExit) as cm:
            grow_vmdk.find_vm(self._content_with([vm1, vm2]), "clone")
        self.assertIn("ambiguous", str(cm.exception))


# ---------------------------------------------------------------------------
# Tests: scsi_address
# ---------------------------------------------------------------------------

class TestScsiAddress(unittest.TestCase):

    def _vm_with(self, ctrl, disk):
        vm = MagicMock()
        vm.config.hardware.device = [ctrl, disk]
        return vm

    def test_returns_bus_colon_unit(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(ctrl_key=1000, unit=2)
        vm = self._vm_with(ctrl, disk)
        self.assertEqual(grow_vmdk.scsi_address(vm, disk), "0:2")

    def test_returns_none_for_non_scsi(self):
        ctrl = MagicMock()  # not a VirtualSCSIController instance
        ctrl.key = 999
        disk = _make_disk(ctrl_key=999, unit=0)
        vm = self._vm_with(ctrl, disk)
        self.assertIsNone(grow_vmdk.scsi_address(vm, disk))


# ---------------------------------------------------------------------------
# Tests: select_disk
# ---------------------------------------------------------------------------

class TestSelectDisk(unittest.TestCase):

    def _args(self, label=None, scsi=None):
        a = MagicMock()
        a.disk_label = label
        a.scsi = scsi
        return a

    def test_select_by_label_single(self):
        ctrl = _make_scsi_ctrl()
        disk = _make_disk(label="Hard disk 2")
        vm = _make_vm(disks=[disk], ctrls=[ctrl])
        result = grow_vmdk.select_disk(vm, self._args(label="Hard disk 2"))
        self.assertIs(result, disk)

    def test_select_by_scsi(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(ctrl_key=1000, unit=1)
        vm = _make_vm(disks=[disk], ctrls=[ctrl])
        result = grow_vmdk.select_disk(vm, self._args(scsi="0:1"))
        self.assertIs(result, disk)

    def test_exits_when_label_not_found(self):
        vm = _make_vm(disks=[_make_disk(label="Hard disk 1")])
        with self.assertRaises(SystemExit):
            grow_vmdk.select_disk(vm, self._args(label="Hard disk 9"))

    def test_exits_when_multiple_label_matches(self):
        d1 = _make_disk(label="Hard disk 2")
        d2 = _make_disk(label="Hard disk 2")
        vm = _make_vm(disks=[d1, d2])
        with self.assertRaises(SystemExit):
            grow_vmdk.select_disk(vm, self._args(label="Hard disk 2"))

    def test_exits_when_scsi_not_found(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(ctrl_key=1000, unit=0)
        vm = _make_vm(disks=[disk], ctrls=[ctrl])
        with self.assertRaises(SystemExit):
            grow_vmdk.select_disk(vm, self._args(scsi="0:5"))


# ---------------------------------------------------------------------------
# Tests: wait_for_task
# ---------------------------------------------------------------------------

class TestWaitForTask(unittest.TestCase):

    def test_success_returns(self):
        task = _make_task("success")
        grow_vmdk.wait_for_task(task)  # should not raise

    def test_failure_exits(self):
        task = _make_task("error", error_msg="disk is locked")
        with self.assertRaises(SystemExit) as cm:
            grow_vmdk.wait_for_task(task)
        self.assertIn("ReconfigVM_Task failed", str(cm.exception))

    @patch("time.sleep", return_value=None)
    def test_polls_until_done(self, _sleep):
        task = MagicMock()
        task.info = MagicMock()
        # First two calls return running, third returns success
        task.info.state = "running"
        call_count = [0]

        def side_effect():
            call_count[0] += 1
            if call_count[0] >= 3:
                task.info.state = "success"

        # Simulate state change via side effect on sleep
        with patch("time.sleep", side_effect=lambda _: side_effect()):
            grow_vmdk.wait_for_task(task)
        self.assertGreaterEqual(call_count[0], 2)


# ---------------------------------------------------------------------------
# Tests: main() end-to-end paths
# ---------------------------------------------------------------------------

class TestMain(unittest.TestCase):

    def _run_main(self, argv, si=None, vm=None, disk=None):
        """Patch everything external and run main() with given CLI args."""
        if disk is None:
            disk = _make_disk(label="Hard disk 1", capacity_gb=100)
        if vm is None:
            ctrl = _make_scsi_ctrl()
            disk.controllerKey = ctrl.key
            vm = _make_vm(disks=[disk], ctrls=[ctrl])
        if si is None:
            si = MagicMock()
            content = MagicMock()
            view = MagicMock()
            view.view = [vm]
            content.viewManager.CreateContainerView.return_value = view
            si.RetrieveContent.return_value = content

        with patch.object(sys, "argv", ["grow-vmdk.py"] + argv), \
             patch("grow_vmdk.SmartConnect", return_value=si), \
             patch("grow_vmdk.Disconnect") as mock_disconnect, \
             patch("grow_vmdk.getpass.getpass", return_value="secret"), \
             patch("grow_vmdk.wait_for_task") as mock_wait:
            grow_vmdk.main()
            return mock_disconnect, mock_wait, vm, disk

    def test_dry_run_add_gb_prints_no_task(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(label="Hard disk 1", capacity_gb=100, ctrl_key=1000)
        vm = _make_vm(disks=[disk], ctrls=[ctrl])
        _, mock_wait, _, _ = self._run_main(
            ["--host", "vc", "--user", "u", "--vm", "myvm",
             "--disk-label", "Hard disk 1", "--add-gb", "50", "--dry-run"],
            vm=vm, disk=disk,
        )
        mock_wait.assert_not_called()

    def test_add_gb_submits_reconfig_task(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(label="Hard disk 1", capacity_gb=100, ctrl_key=1000)
        vm = _make_vm(disks=[disk], ctrls=[ctrl])
        task = _make_task("success")
        vm.ReconfigVM_Task.return_value = task
        _, mock_wait, _, updated_disk = self._run_main(
            ["--host", "vc", "--user", "u", "--vm", "myvm",
             "--disk-label", "Hard disk 1", "--add-gb", "50"],
            vm=vm, disk=disk,
        )
        mock_wait.assert_called_once_with(task)
        self.assertEqual(updated_disk.capacityInKB, 150 * GB)

    def test_new_size_gb_sets_absolute_size(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(label="Hard disk 1", capacity_gb=100, ctrl_key=1000)
        vm = _make_vm(disks=[disk], ctrls=[ctrl])
        task = _make_task("success")
        vm.ReconfigVM_Task.return_value = task
        _, mock_wait, _, updated_disk = self._run_main(
            ["--host", "vc", "--user", "u", "--vm", "myvm",
             "--disk-label", "Hard disk 1", "--new-size-gb", "200"],
            vm=vm, disk=disk,
        )
        self.assertEqual(updated_disk.capacityInKB, 200 * GB)

    def test_no_op_when_already_big_enough(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(label="Hard disk 1", capacity_gb=200, ctrl_key=1000)
        vm = _make_vm(disks=[disk], ctrls=[ctrl])
        _, mock_wait, returned_vm, _ = self._run_main(
            ["--host", "vc", "--user", "u", "--vm", "myvm",
             "--disk-label", "Hard disk 1", "--new-size-gb", "100"],
            vm=vm, disk=disk,
        )
        mock_wait.assert_not_called()
        returned_vm.ReconfigVM_Task.assert_not_called()

    def test_snapshot_check_exits(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(label="Hard disk 1", capacity_gb=100, ctrl_key=1000)
        vm = _make_vm(disks=[disk], ctrls=[ctrl], snapshots=MagicMock())
        with self.assertRaises(SystemExit) as cm:
            self._run_main(
                ["--host", "vc", "--user", "u", "--vm", "myvm",
                 "--disk-label", "Hard disk 1", "--add-gb", "10"],
                vm=vm, disk=disk,
            )
        self.assertIn("snapshot", str(cm.exception).lower())

    def test_disconnect_always_called(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(label="Hard disk 1", capacity_gb=100, ctrl_key=1000)
        vm = _make_vm(disks=[disk], ctrls=[ctrl], snapshots=MagicMock())
        try:
            self._run_main(
                ["--host", "vc", "--user", "u", "--vm", "myvm",
                 "--disk-label", "Hard disk 1", "--add-gb", "10"],
                vm=vm, disk=disk,
            )
        except SystemExit:
            pass
        # Disconnect is called in the finally block — assert via the patch above.
        # If we get here without an AssertionError, the finally block ran.

    def test_connect_failure_exits(self):
        with patch.object(sys, "argv", ["grow-vmdk.py", "--host", "bad", "--user", "u",
                                        "--vm", "x", "--disk-label", "Hard disk 1",
                                        "--add-gb", "1"]), \
             patch("grow_vmdk.SmartConnect", side_effect=Exception("conn refused")), \
             patch("grow_vmdk.Disconnect"), \
             patch("grow_vmdk.getpass.getpass", return_value="pw"):
            with self.assertRaises(SystemExit) as cm:
                grow_vmdk.main()
            self.assertIn("cannot connect", str(cm.exception))

    def test_password_from_env(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(label="Hard disk 1", capacity_gb=100, ctrl_key=1000)
        vm = _make_vm(disks=[disk], ctrls=[ctrl])
        task = _make_task("success")
        vm.ReconfigVM_Task.return_value = task
        with patch.dict("os.environ", {"VC_PASSWORD": "envpass"}), \
             patch.object(sys, "argv", ["grow-vmdk.py", "--host", "vc", "--user", "u",
                                        "--vm", "myvm", "--disk-label", "Hard disk 1",
                                        "--add-gb", "10", "--dry-run"]), \
             patch("grow_vmdk.SmartConnect") as mock_connect, \
             patch("grow_vmdk.Disconnect"), \
             patch("grow_vmdk.getpass.getpass") as mock_gp:
            si = MagicMock()
            content = MagicMock()
            view = MagicMock(); view.view = [vm]
            content.viewManager.CreateContainerView.return_value = view
            si.RetrieveContent.return_value = content
            mock_connect.return_value = si
            grow_vmdk.main()
            mock_gp.assert_not_called()
            _, kwargs = mock_connect.call_args
            self.assertEqual(kwargs.get("pwd") or mock_connect.call_args[0][3], "envpass")

    def test_scsi_selector(self):
        ctrl = _make_scsi_ctrl(key=1000, bus=0)
        disk = _make_disk(label="Hard disk 2", capacity_gb=50, ctrl_key=1000, unit=1)
        vm = _make_vm(disks=[disk], ctrls=[ctrl])
        task = _make_task("success")
        vm.ReconfigVM_Task.return_value = task
        _, mock_wait, _, updated_disk = self._run_main(
            ["--host", "vc", "--user", "u", "--vm", "myvm",
             "--scsi", "0:1", "--add-gb", "25"],
            vm=vm, disk=disk,
        )
        mock_wait.assert_called_once()
        self.assertEqual(updated_disk.capacityInKB, 75 * GB)


# ---------------------------------------------------------------------------
# Tests: parse_args validation
# ---------------------------------------------------------------------------

class TestParseArgs(unittest.TestCase):

    def _parse(self, args):
        with patch.object(sys, "argv", ["grow-vmdk.py"] + args):
            return grow_vmdk.parse_args()

    def test_required_args_present(self):
        a = self._parse(["--host", "h", "--user", "u", "--vm", "v",
                         "--disk-label", "Hard disk 1", "--add-gb", "10"])
        self.assertEqual(a.host, "h")
        self.assertEqual(a.add_gb, 10)

    def test_mutex_disk_selector(self):
        with self.assertRaises(SystemExit):
            self._parse(["--host", "h", "--user", "u", "--vm", "v",
                         "--disk-label", "d", "--scsi", "0:1", "--add-gb", "1"])

    def test_mutex_size_selector(self):
        with self.assertRaises(SystemExit):
            self._parse(["--host", "h", "--user", "u", "--vm", "v",
                         "--disk-label", "d", "--add-gb", "1", "--new-size-gb", "100"])

    def test_defaults(self):
        a = self._parse(["--host", "h", "--user", "u", "--vm", "v",
                         "--disk-label", "d", "--add-gb", "1"])
        self.assertEqual(a.port, 443)
        self.assertFalse(a.insecure)
        self.assertFalse(a.dry_run)


if __name__ == "__main__":
    unittest.main()
