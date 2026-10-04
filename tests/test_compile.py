import os
import pathlib
import py_compile
import re
import shutil
import subprocess

import pytest

import repo

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
