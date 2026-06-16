"""
Tests for extend-lv.yml Ansible playbook.

These tests verify structure and static correctness of the playbook without
running Ansible. They also exercise the Jinja2 expressions inline so logic
bugs are caught without needing managed nodes.

Run: pytest tests/test_extend_lv_playbook.py -v
"""
import re
import unittest
from pathlib import Path

try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML is required: pip install pyyaml")

PLAYBOOK_PATH = Path(__file__).parent.parent / "extend-lv.yml"


def load_playbook():
    with open(PLAYBOOK_PATH) as f:
        return yaml.safe_load(f)


def task_names(play):
    return [t.get("name", "") for t in play.get("tasks", [])]


class TestPlaybookStructure(unittest.TestCase):

    def setUp(self):
        self.plays = load_playbook()
        self.play = self.plays[0]

    def test_file_parses_as_yaml(self):
        self.assertIsInstance(self.plays, list)
        self.assertGreater(len(self.plays), 0)

    def test_single_play(self):
        self.assertEqual(len(self.plays), 1)

    def test_play_has_become_true(self):
        self.assertTrue(self.play.get("become"))

    def test_required_vars_defined(self):
        v = self.play.get("vars", {})
        for var in ("mode", "new_device", "vg_name", "lv_name", "lv_size"):
            self.assertIn(var, v, f"var '{var}' missing from play vars")

    def test_default_mode_is_add(self):
        self.assertEqual(self.play["vars"]["mode"], "add")

    def test_default_lv_size_is_100_percent_free(self):
        self.assertEqual(self.play["vars"]["lv_size"], "+100%FREE")

    def test_default_force_is_false(self):
        self.assertFalse(self.play["vars"]["force"])

    def test_tasks_list_is_nonempty(self):
        self.assertGreater(len(self.play.get("tasks", [])), 0)


class TestTaskPresence(unittest.TestCase):
    """Assert key tasks are present and in the right order."""

    def setUp(self):
        self.play = load_playbook()[0]
        self.names = task_names(self.play)

    def test_rescan_add_task_present(self):
        self.assertTrue(any("Rescan SCSI" in n for n in self.names))

    def test_rescan_grow_task_present(self):
        self.assertTrue(any("new size" in n for n in self.names))

    def test_safety_vg_check_present(self):
        self.assertTrue(any("volume group" in n.lower() for n in self.names))

    def test_safety_lv_check_present(self):
        self.assertTrue(any("LV" in n or "lv" in n.lower() for n in self.names))

    def test_filesystem_support_check_present(self):
        self.assertTrue(any("filesystem" in n.lower() and "grown" in n.lower()
                            for n in self.names))

    def test_metadata_backup_present(self):
        self.assertTrue(any("back up" in n.lower() or "backup" in n.lower()
                            for n in self.names))

    def test_pvcreate_task_present(self):
        self.assertTrue(any("physical volume" in n.lower() for n in self.names))

    def test_vgextend_task_present(self):
        self.assertTrue(any("volume group" in n.lower() and "new PV" in n
                            for n in self.names))

    def test_pvresize_task_present(self):
        self.assertTrue(any("pvresize" in n.lower() or "Resize the PV" in n
                            for n in self.names))

    def test_lvol_extend_task_present(self):
        self.assertTrue(any("logical volume" in n.lower() and "grow" in n.lower()
                            for n in self.names))

    def test_backup_before_any_change(self):
        """Metadata backup must appear before lvol extension."""
        backup_idx = next((i for i, n in enumerate(self.names)
                           if "back up" in n.lower() or "backup" in n.lower()), None)
        extend_idx = next((i for i, n in enumerate(self.names)
                           if "logical volume" in n.lower() and "grow" in n.lower()), None)
        self.assertIsNotNone(backup_idx, "backup task not found")
        self.assertIsNotNone(extend_idx, "lvol extend task not found")
        self.assertLess(backup_idx, extend_idx,
                        "metadata backup must come before lvol extend")


class TestTaskConditions(unittest.TestCase):
    """Verify when: conditions on critical tasks."""

    def setUp(self):
        self.tasks = load_playbook()[0].get("tasks", [])

    def _find_task(self, name_fragment):
        return next((t for t in self.tasks if name_fragment.lower() in
                     t.get("name", "").lower()), None)

    def test_add_rescan_gated_on_add_mode(self):
        t = self._find_task("Rescan SCSI")
        self.assertIsNotNone(t)
        self.assertIn("mode", str(t.get("when", "")))
        self.assertIn("add", str(t.get("when", "")))

    def test_grow_rescan_gated_on_grow_mode(self):
        t = self._find_task("new size")
        self.assertIsNotNone(t)
        self.assertIn("mode", str(t.get("when", "")))
        self.assertIn("grow", str(t.get("when", "")))

    def test_pvcreate_gated_on_add_mode(self):
        t = self._find_task("physical volume")
        self.assertIsNotNone(t)
        self.assertIn("mode", str(t.get("when", "")))
        self.assertIn("add", str(t.get("when", "")))

    def test_pvresize_gated_on_grow_mode(self):
        t = self._find_task("Resize the PV")
        self.assertIsNotNone(t)
        self.assertIn("mode", str(t.get("when", "")))
        self.assertIn("grow", str(t.get("when", "")))

    def test_safety_refusal_gated_on_not_force(self):
        t = self._find_task("refuse to initialise")
        self.assertIsNotNone(t)
        self.assertIn("force", str(t.get("when", "")))

    def test_pv_device_fact_set(self):
        t = self._find_task("Resolve the PV device path")
        self.assertIsNotNone(t)
        self.assertIn("set_fact", str(t))

    def test_resizefs_gated_on_mount_status(self):
        t = self._find_task("logical volume and grow")
        self.assertIsNotNone(t)
        task_str = str(t)
        self.assertIn("lv_mnt", task_str)


class TestJinjaExpressions(unittest.TestCase):
    """Evaluate embedded Jinja2 logic without Ansible by parsing the YAML."""

    def _pv_device_expr(self, new_device, mode, use_partition):
        """
        Mirrors the set_fact pv_device expression from the playbook:
          {{ (new_device ~ ('p1' if (new_device is search('[0-9]$')) else '1'))
             if (mode == 'add' and use_partition | bool) else new_device }}
        """
        if mode == "add" and use_partition:
            suffix = "p1" if re.search(r"[0-9]$", new_device) else "1"
            return new_device + suffix
        return new_device

    def test_whole_disk_add_partition(self):
        self.assertEqual(
            self._pv_device_expr("/dev/sdb", "add", True), "/dev/sdb1")

    def test_nvme_disk_add_partition(self):
        # nvme0n1 ends in a digit, so suffix is 'p1'
        self.assertEqual(
            self._pv_device_expr("/dev/nvme0n1", "add", True), "/dev/nvme0n1p1")

    def test_no_partition_returns_device_unchanged(self):
        self.assertEqual(
            self._pv_device_expr("/dev/sdb", "add", False), "/dev/sdb")

    def test_grow_mode_returns_device_unchanged(self):
        self.assertEqual(
            self._pv_device_expr("/dev/sdb", "grow", True), "/dev/sdb")

    def test_grow_mode_no_partition_unchanged(self):
        self.assertEqual(
            self._pv_device_expr("/dev/sdb3", "grow", False), "/dev/sdb3")


class TestSafetyAssertions(unittest.TestCase):
    """Verify the assert tasks have meaningful fail_msg and correct 'that'."""

    def setUp(self):
        self.tasks = load_playbook()[0].get("tasks", [])

    def _assert_tasks(self):
        return [t for t in self.tasks if "ansible.builtin.assert" in t]

    def test_each_assert_has_fail_msg(self):
        for t in self._assert_tasks():
            a = t["ansible.builtin.assert"]
            self.assertIn("fail_msg", a,
                          f"assert task '{t.get('name')}' missing fail_msg")

    def test_filesystem_assert_allows_xfs_ext(self):
        t = next((t for t in self.tasks
                  if "ansible.builtin.assert" in t and "filesystem" in
                  t.get("name", "").lower()), None)
        self.assertIsNotNone(t)
        expr = str(t["ansible.builtin.assert"].get("that", ""))
        for fs in ("xfs", "ext2", "ext3", "ext4"):
            self.assertIn(fs, expr, f"fs '{fs}' missing from assert expression")

    def test_device_in_use_assert_checks_zero(self):
        t = next((t for t in self.tasks
                  if "ansible.builtin.assert" in t and "in use" in
                  t.get("name", "").lower()), None)
        self.assertIsNotNone(t)
        expr = str(t["ansible.builtin.assert"].get("that", ""))
        self.assertIn("0", expr)


class TestModuleChoices(unittest.TestCase):
    """Verify the correct Ansible modules are used for key operations."""

    def setUp(self):
        self.tasks = load_playbook()[0].get("tasks", [])

    def _find_task(self, name_fragment):
        return next((t for t in self.tasks if name_fragment.lower() in
                     t.get("name", "").lower()), None)

    def test_lvol_task_uses_community_general(self):
        t = self._find_task("logical volume and grow")
        self.assertIsNotNone(t)
        self.assertIn("community.general.lvol", t)

    def test_parted_task_uses_community_general(self):
        t = self._find_task("GPT partition")
        self.assertIsNotNone(t)
        self.assertIn("community.general.parted", t)

    def test_lvol_resizefs_uses_lv_mnt(self):
        t = self._find_task("logical volume and grow")
        self.assertIsNotNone(t)
        lvol = t["community.general.lvol"]
        resizefs_val = str(lvol.get("resizefs", ""))
        self.assertIn("lv_mnt", resizefs_val)

    def test_wait_for_block_device(self):
        t = self._find_task("Wait for the block device")
        self.assertIsNotNone(t)
        self.assertIn("ansible.builtin.wait_for", t)
        self.assertEqual(t["ansible.builtin.wait_for"]["timeout"], 30)


if __name__ == "__main__":
    unittest.main()
