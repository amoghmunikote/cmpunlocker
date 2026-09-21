import subprocess
import sys

import pytest

import repo


@pytest.mark.parametrize("profile", ["8gb", "10gb", "mixed"])
def test_constants_accept_base_and_optional_patches(profile):
    r = subprocess.run([
        sys.executable, str(repo.ROOT / "tools/read-constants.py"),
        str(repo.ROOT / "common/constants.yaml"), str(repo.ROOT / "driver/patches"),
        str(repo.ROOT / "driver/build.sh"), profile,
    ], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "UNLOCK_LABEL=" in r.stdout


@pytest.mark.parametrize("enabled", ["0", "1"])
def test_module_options_keep_gen2_and_select_bar1(enabled):
    r = subprocess.run(["bash", str(repo.ROOT / "tools/module-options.sh"), enabled],
                       capture_output=True, text=True, check=True)
    assert len(r.stdout.splitlines()) == 1
    assert 'NVreg_RegistryDwords="RmForceEnableGen2=1;RMPcieLinkSpeed=0x1' in r.stdout
    assert ("RMForceStaticBar1=1;RMPcieP2PType=1" in r.stdout) == (enabled == "1")
    assert "ForceP2P=" not in r.stdout


@pytest.mark.parametrize("mode", ["off", "bar1", "mailbox"])
@pytest.mark.parametrize("no_gen2", ["0", "1"])
def test_transport_options_are_exclusive(mode, no_gen2):
    r = subprocess.run(["bash", str(repo.ROOT / "tools/module-options.sh"), mode, no_gen2],
                       capture_output=True, text=True, check=True)
    assert ("RmForceEnableGen2" in r.stdout) == (no_gen2 == "0")
    assert ("RMPcieLinkSpeed" in r.stdout) == (no_gen2 == "0")
    assert ("RMForceStaticBar1" in r.stdout) == (mode == "bar1")
    assert ("RMPcieP2PType" in r.stdout) == (mode == "bar1")
    assert ("PeerMappingOverride=1;ForceP2P=17" in r.stdout) == (mode == "mailbox")
    assert ("NVreg_EnableStreamMemOPs=1" in r.stdout) == (mode == "mailbox")


def test_module_options_reject_invalid_mode():
    r = subprocess.run(["bash", str(repo.ROOT / "tools/module-options.sh"), "bad"],
                       capture_output=True, text=True)
    assert r.returncode != 0
    assert not r.stdout


@pytest.mark.parametrize("sizes,expected", [
    ([64, 64, 64], 0), ([64, 0, 64], 1), ([64, 32, 64], 1), ([], 1),
])
def test_bar1_requires_full_assignment_on_every_card(tmp_path, sizes, expected):
    for index, gib in enumerate(sizes):
        device = tmp_path / f"0000:{index + 1:02x}:00.0"
        device.mkdir()
        (device / "vendor").write_text("0x10de\n")
        (device / "device").write_text("0x20c2\n")
        start = (index + 1) * 128 * 1024 ** 3 if gib else 0
        end = start + gib * 1024 ** 3 - 1 if gib else 0
        (device / "resource").write_text(f"0 0 0\n{start:x} {end:x} 200\n")
    r = subprocess.run([sys.executable, str(repo.ROOT / "tools/check-bar1.py"),
                        "--sysfs-root", str(tmp_path)], capture_output=True, text=True)
    assert r.returncode == expected, r.stdout + r.stderr
