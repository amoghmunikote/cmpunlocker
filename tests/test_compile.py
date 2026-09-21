import os
import pathlib
import py_compile
import re
import shutil
import subprocess
import sys

import pytest

import repo
from test_patches import patched_source

PY_FILES = repo.py_files()
EMBEDDED = [s for s in repo.sh_files() if "<<'PY'" in s.read_text()]
PY_HEREDOC = re.compile(r"<<'PY'\n(.*?)\nPY\n", re.S)
assert PY_FILES and EMBEDDED


@pytest.mark.parametrize("path", PY_FILES, ids=[repo.rel(p) for p in PY_FILES])
def test_python_compiles(path, tmp_path):
    py_compile.compile(str(path), cfile=str(tmp_path / "out.pyc"), doraise=True)


@pytest.mark.parametrize("script", EMBEDDED, ids=[repo.rel(p) for p in EMBEDDED])
def test_embedded_python_compiles(script):
    for n, block in enumerate(PY_HEREDOC.findall(script.read_text())):
        compile(block, "%s:PY%d" % (repo.rel(script), n), "exec")


@pytest.mark.skipif(sys.platform != "linux", reason="requires Linux kernel headers")
def test_passthrough_module_builds(tmp_path):
    builds = [b for b in pathlib.Path("/lib/modules").glob("*/build") if b.is_dir()]
    running = pathlib.Path("/lib/modules", os.uname().release, "build")
    build = running if running.is_dir() else (builds[-1] if builds else None)
    assert build, "no kernel headers under /lib/modules/*/build"
    for name in ("cmp_no_bus_reset.c", "Makefile"):
        shutil.copy(repo.ROOT / "driver" / "passthrough" / name, tmp_path / name)
    r = subprocess.run(["make", "-C", str(tmp_path), "KVER=" + build.parent.name],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert (tmp_path / "cmp_no_bus_reset.ko").is_file()


@pytest.mark.skipif(sys.platform != "linux" and not os.environ.get("CMPUNLOCKER_TEST_CC"),
                    reason="requires a Linux x86-64 compiler (or CMPUNLOCKER_TEST_CC)")
@pytest.mark.parametrize("version", repo.versions())
@pytest.mark.parametrize("mode,gen2", [("bar1", True), ("mailbox", False)])
def test_p2p_resource_manager_sources_compile(version, mode, gen2):
    compiler = os.environ.get("CMPUNLOCKER_TEST_CC", "cc")
    objects = ["gpu", "kern_bus", "kernel_bif", "kern_bus_gp100", "kern_bus_gm107",
               "nv_gpu_ops", "p2p_caps", "kernel_gsp", "mem_scrub", "kern_bus_gm200"]
    with patched_source(version, p2p=mode, gen2=gen2) as src:
        r = subprocess.run([
            "make", "-C", str(src / "src/nvidia"), "-j2",
            "TARGET_OS=Linux", "TARGET_ARCH=x86_64", "CC=" + compiler,
            *["_out/Linux_x86_64/" + name + ".o" for name in objects],
        ], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr
