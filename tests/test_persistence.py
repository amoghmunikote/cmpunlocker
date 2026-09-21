import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest

import repo

spec = importlib.util.spec_from_file_location("maintenance", repo.ROOT / "persist/manage.py")
maintenance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(maintenance)

KERNEL = "6.8.0-100-generic"
NEXT_KERNEL = "6.8.0-101-generic"
VERSION = "610.57.04"


class Commands:
    def __init__(self, root):
        self.root = root
        self.calls = []
        self.held = {"libnvidia-compute-610:amd64"}  # A user-owned hold.
        self.fail_build = False
        self.fail_bar1 = False

    def __call__(self, args, **kwargs):
        self.calls.append((args, kwargs))
        out = ""
        if args[0] == "modinfo":
            kernel = args[args.index("-k") + 1]
            if "-n" in args:
                out = str(self.root / f"lib/modules/{kernel}/updates/cmpunlocker/nvidia.ko")
            elif "vermagic" in args:
                out = kernel + " SMP mod_unload"
            else:
                out = VERSION
        elif args[0] == "dpkg-query":
            out = ("libnvidia-compute-610:amd64\tinstalled\n"
                   "nvidia-driver-610-open\tinstalled\n"
                   "nvidia-firmware-610-610.57.04\tinstalled\n"
                   "nvidia-gpu-firmware\tinstalled\nfirmware-nvidia\tinstalled\n"
                   "libnvidia-old\tconfig-files\n")
        elif args[:2] == ["apt-mark", "showhold"]:
            out = "\n".join(sorted(self.held))
        elif args[:2] == ["apt-mark", "hold"]:
            self.held.add(args[2])
        elif args[:2] == ["apt-mark", "unhold"]:
            self.held.remove(args[2])
        elif args[0] == "bash":
            if self.fail_build:
                raise subprocess.CalledProcessError(2, args)
            kernel = kwargs["env"]["CMPUNLOCKER_KVER"]
            modules = self.root / f"lib/modules/{kernel}/updates/cmpunlocker"
            modules.mkdir(parents=True, exist_ok=True)
            for name in ("nvidia.ko", "nvidia-uvm.ko"):
                (modules / name).write_bytes(b"new driver")
            if kwargs["env"]["CMPUNLOCKER_BUILD_PASSTHROUGH"] == "1":
                (modules / "cmp_no_bus_reset.ko").write_bytes(b"passthrough")
        elif any(str(arg).endswith("check-bar1.py") for arg in args) and self.fail_bar1:
            raise subprocess.CalledProcessError(1, args)
        return subprocess.CompletedProcess(args, 0, stdout=out, stderr="")


@pytest.fixture
def installed(tmp_path):
    root = tmp_path / "root"
    (root / "etc").mkdir(parents=True)
    (root / "etc/debian_version").write_text("24.04")
    commands = Commands(root)
    manager = maintenance.Manager(root, commands)
    source = tmp_path / "source"
    # A small payload exercises offline installation without executing root code.
    for name in ("common", "tools", "persist", "driver/patches", "driver/passthrough", "driver/.build"):
        (source / name).mkdir(parents=True)
    for name in ("common/constants.yaml", "tools/read-constants.py", "tools/module-options.sh",
                 "tools/gsp-restore.py", "tools/check-bar1.py", "persist/manage.py",
                 "persist/depmod-cmpunlocker.conf", "persist/modprobe-cmpunlocker.conf",
                 "driver/build.sh", "driver/VERSION", "driver/patches/memory.patch",
                 "driver/passthrough/Makefile", "driver/passthrough/cmp_no_bus_reset.c"):
        (source / name).write_text(name + "\n")
    (source / f"driver/.build/open-gpu-kernel-modules-{VERSION}.tar.gz").write_bytes(b"cached archive")
    modules = manager.modules(KERNEL)
    modules.mkdir(parents=True)
    for name, value in {"driver_version": VERSION, "card_profile": "mixed", "p2p_mode": "mailbox",
                        "gen2_disabled": "1", "gpu_inventory": "0000:01:00.0 20c2 8gb 65536\n"}.items():
        (modules / name).write_text(value)
    for name in ("nvidia.ko", "nvidia-uvm.ko", "cmp_no_bus_reset.ko"):
        (modules / name).write_bytes(b"initial driver")
    manager.install(source, KERNEL)
    return manager, commands, source


def test_install_caches_complete_payload_and_preserves_user_holds(installed):
    manager, commands, _ = installed
    assert manager.current(KERNEL, manager.config())
    assert (manager.payload / "common/constants.yaml").exists()
    assert (manager.payload / "tools/module-options.sh").exists()
    assert (manager.payload / f"driver/.build/open-gpu-kernel-modules-{VERSION}.tar.gz").exists()
    for hook in manager.hooks()[:2]:
        assert 'rebuild "$1"' in hook.read_text()
    ledger = json.loads((manager.state / "apt-holds.json").read_text())
    assert "libnvidia-compute-610:amd64" not in ledger
    assert "nvidia-firmware-610-610.57.04" in ledger
    assert "nvidia-gpu-firmware" not in commands.held
    assert "libnvidia-old" not in commands.held


def test_real_offline_payload_passes_shared_constants_validation(installed):
    manager, _, _ = installed
    manager.install(repo.ROOT, KERNEL, persist=False, pin=False)
    root = manager.payload
    result = subprocess.run([
        sys.executable, str(root / "tools/read-constants.py"),
        str(root / "common/constants.yaml"), str(root / "driver/patches"),
        str(root / "driver/build.sh"), "mixed",
    ], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr


def test_rebuild_replays_every_option_for_target_kernel(installed, monkeypatch):
    manager, commands, source = installed
    monkeypatch.setenv("CMPUNLOCKER_P2P_MODE", "bar1")
    monkeypatch.setenv("CMPUNLOCKER_BUILD_DIR", "/unrelated")
    # The user can move/delete the clone; rebuilding only uses the saved copy.
    source.rename(source.with_name("moved"))
    manager.path(f"/lib/modules/{NEXT_KERNEL}/build").mkdir(parents=True)
    manager.rebuild(NEXT_KERNEL)
    builds = [(args, kw) for args, kw in commands.calls if args[0] == "bash"]
    assert len(builds) == 1
    env = builds[0][1]["env"]
    assert env["CMPUNLOCKER_KVER"] == NEXT_KERNEL
    assert env["CMPUNLOCKER_DRIVER_VERSION"] == VERSION
    assert env["CMPUNLOCKER_P2P_MODE"] == "mailbox"
    assert env["CMPUNLOCKER_DISABLE_GEN2"] == "1"
    assert env["CMPUNLOCKER_CARD_PROFILE"] == "mixed"
    assert env["CMPUNLOCKER_BUILD_PASSTHROUGH"] == "1"
    assert "CMPUNLOCKER_BUILD_DIR" not in env
    assert manager.current(NEXT_KERNEL, manager.config())
    manager.rebuild(NEXT_KERNEL)
    assert len([args for args, _ in commands.calls if args[0] == "bash"]) == 1
    assert not any(args[0] in ("modprobe", "rmmod", "insmod") for args, _ in commands.calls)


def test_header_hook_can_recover_from_missing_headers(installed):
    manager, _, _ = installed
    with pytest.raises(RuntimeError, match="Headers missing"):
        manager.rebuild(NEXT_KERNEL)
    assert (manager.state / f"failed-{NEXT_KERNEL}").exists()
    manager.path(f"/lib/modules/{NEXT_KERNEL}/build").mkdir(parents=True)
    manager.rebuild(NEXT_KERNEL)
    assert not (manager.state / f"failed-{NEXT_KERNEL}").exists()


def test_failed_rebuild_does_not_claim_success_or_touch_working_kernel(installed):
    manager, commands, _ = installed
    manager.path(f"/lib/modules/{NEXT_KERNEL}/build").mkdir(parents=True)
    commands.fail_build = True
    with pytest.raises(subprocess.CalledProcessError):
        manager.rebuild(NEXT_KERNEL)
    assert manager.current(KERNEL, manager.config())
    assert not manager.current(NEXT_KERNEL, manager.config())
    assert (manager.state / f"failed-{NEXT_KERNEL}").exists()


def test_reinstall_changes_mode_and_invalidates_other_kernel_builds(installed):
    manager, _, source = installed
    manager.path(f"/lib/modules/{NEXT_KERNEL}/build").mkdir(parents=True)
    manager.rebuild(NEXT_KERNEL)
    (manager.modules(KERNEL) / "p2p_mode").write_text("off")
    (manager.modules(KERNEL) / "gen2_disabled").write_text("0")
    manager.install(source, KERNEL, persist=False, pin=False)
    assert manager.config()["p2p"] == "off"
    assert manager.current(KERNEL, manager.config())
    assert not manager.current(NEXT_KERNEL, manager.config())
    assert not any(hook.exists() for hook in manager.hooks())


def test_boot_check_requires_bar1_only_for_bar1_mode(installed):
    manager, commands, source = installed
    commands.fail_bar1 = True
    manager.boot_check(KERNEL)  # Mailbox should never run the large BAR1 check.
    (manager.modules(KERNEL) / "p2p_mode").write_text("bar1")
    manager.install(source, KERNEL)
    with pytest.raises(subprocess.CalledProcessError):
        manager.boot_check(KERNEL)


def test_payload_or_module_corruption_is_detected(installed):
    manager, _, _ = installed
    (manager.modules(KERNEL) / "nvidia.ko").write_bytes(b"stock replacement")
    assert not manager.current(KERNEL, manager.config())
    with pytest.raises(RuntimeError, match="Missing, stale or failed"):
        manager.boot_check(KERNEL)
    (manager.payload / "tools/module-options.sh").write_text("changed")
    with pytest.raises(RuntimeError, match="payload changed"):
        manager.rebuild(KERNEL)


def test_uninstall_keeps_preexisting_holds_and_custom_payload(installed):
    manager, commands, _ = installed
    custom = manager.data / "dmem.bin"
    custom.write_bytes(b"user override")
    manager.uninstall()
    assert commands.held == {"libnvidia-compute-610:amd64"}
    assert custom.read_bytes() == b"user override"
    assert not manager.config_file.exists()
    assert not manager.payload.exists()
    assert not any(hook.exists() for hook in manager.hooks())


@pytest.mark.parametrize("bad", ["../etc", "/tmp/bad", "", "$(uname -r)", "6.8\nother"])
def test_reject_bad_kernel_name(bad):
    with pytest.raises(ValueError):
        maintenance.kernel_version(bad)
