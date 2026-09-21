import os
import pathlib
import shutil
import subprocess
import tempfile
import urllib.request
from contextlib import contextmanager

import pytest

import repo

URL = "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/%s.tar.gz"
CACHE = pathlib.Path(os.environ.get("CMPUNLOCKER_BUILD_DIR", repo.ROOT / "driver" / ".build"))
PATCHES = repo.ROOT / "driver" / "patches"
VERSIONS = repo.versions()
assert VERSIONS, "driver/VERSION lists no versions"


def tarball(version):
    path = CACHE / ("open-gpu-kernel-modules-%s.tar.gz" % version)
    if not path.is_file():
        CACHE.mkdir(parents=True, exist_ok=True)
        partial = path.with_name(path.name + ".partial")
        with urllib.request.urlopen(URL % version, timeout=60) as resp, open(partial, "wb") as out:
            shutil.copyfileobj(resp, out)
        partial.replace(path)
    return path


def test_patch_order_covers_patch_dir():
    assert set(repo.patch_order("bar1") + repo.patch_order("mailbox")) == {p.name for p in PATCHES.glob("*.patch")}


@pytest.mark.parametrize("version", VERSIONS)
@pytest.mark.parametrize("p2p", ["off", "bar1", "mailbox"])
@pytest.mark.parametrize("gen2", [False, True], ids=["no-gen2", "gen2"])
def test_patches_apply(version, p2p, gen2):
    with patched_source(version, p2p, gen2) as src:
        gsp = (src / "src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c").read_text()
        # Tuning must remain a userspace operation with accessible HBM windows
        # in every transport/Gen2 combination, including all live unicast FBPAs.
        assert "SEC2_POSTBL_FBPA_UC_PLL_PLM" in gsp
        assert '"FBPA_MEM"' in gsp and '"FBPA_PLL0"' in gsp
        assert "fbpaOrphaned" in gsp
        assert "CMPUNLOCK_MCLK_NDIV" not in gsp
        assert '"/var/lib/cmpunlocker/dmem.bin"' in gsp
        assert ("P2P_TRAP31" in gsp) == (p2p == "mailbox")
        assert ("PCIE_GEN2_LINK_CAP_ADDR" in gsp) == gen2
        nv = (src / "kernel-open/nvidia/nv.c").read_text()
        assert ("nv_cmp170hx_retrain_gen2" in nv) == gen2


@contextmanager
def patched_source(version, p2p, gen2=True):
    assert shutil.which("patch"), "GNU patch is not installed"
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["tar", "-xzf", str(tarball(version)), "-C", tmp], check=True)
        src = pathlib.Path(tmp, "open-gpu-kernel-modules-" + version)
        assert src.is_dir(), os.listdir(tmp)
        for name in repo.patch_order(p2p=p2p, gen2=gen2):
            r = subprocess.run(["patch", "--batch", "--forward", "--fuzz=0", "-p1", "-i", str(PATCHES / name)], cwd=src,
                               stdin=subprocess.DEVNULL, capture_output=True, text=True)
            assert r.returncode == 0, "%s on %s:\n%s%s" % (name, version, r.stdout, r.stderr)
        yield src
