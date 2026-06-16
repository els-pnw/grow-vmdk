"""
Session-wide setup that must happen before any test module is imported:

1. Stub out pyvmomi (not needed in test env; the real API is mocked per-test).
2. Load grow-vmdk.py (hyphenated filename) as the 'grow_vmdk' module alias.
"""
import importlib.util
import sys
import types
from pathlib import Path
from unittest.mock import MagicMock

ROOT = Path(__file__).parent.parent


def _install_pyvmomi_stubs():
    """Install minimal pyvmomi stubs so grow-vmdk.py imports without the package."""
    vim_stub = types.ModuleType("vim")
    vim_stub.VirtualMachine = type("VirtualMachine", (), {})

    state = types.SimpleNamespace(queued="queued", running="running",
                                  success="success", error="error")
    vim_stub.TaskInfo = types.SimpleNamespace(State=state)

    device_ns = types.SimpleNamespace(
        VirtualDisk=type("VirtualDisk", (), {}),
        VirtualSCSIController=type("VirtualSCSIController", (), {}),
        VirtualDeviceConfigSpec=MagicMock(),
    )
    device_ns.VirtualDeviceConfigSpec.Operation = types.SimpleNamespace(edit="edit")
    vim_stub.vm = types.SimpleNamespace(
        device=device_ns,
        ConfigSpec=MagicMock(),
    )

    pyVmomi_pkg = types.ModuleType("pyVmomi")
    pyVmomi_pkg.vim = vim_stub

    connect_mod = types.ModuleType("pyVim.connect")
    connect_mod.SmartConnect = MagicMock()
    connect_mod.Disconnect = MagicMock()

    pyVim_pkg = types.ModuleType("pyVim")
    pyVim_pkg.connect = connect_mod

    sys.modules.setdefault("pyVmomi", pyVmomi_pkg)
    sys.modules.setdefault("pyVim", pyVim_pkg)
    sys.modules.setdefault("pyVim.connect", connect_mod)

    return vim_stub


# Install stubs before grow-vmdk.py is imported.
VIM = _install_pyvmomi_stubs()

# Load grow-vmdk.py under the importable alias 'grow_vmdk'.
if "grow_vmdk" not in sys.modules:
    spec = importlib.util.spec_from_file_location("grow_vmdk", ROOT / "grow-vmdk.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["grow_vmdk"] = mod
    spec.loader.exec_module(mod)
