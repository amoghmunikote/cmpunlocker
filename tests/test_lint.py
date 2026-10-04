import shutil
import subprocess

import pytest

import repo

SCRIPTS = repo.sh_files()
IDS = [repo.rel(p) for p in SCRIPTS]
assert SCRIPTS


def run(*cmd):
    return subprocess.run(cmd, cwd=repo.ROOT, capture_output=True, text=True)


@pytest.mark.parametrize("script", SCRIPTS, ids=IDS)
def test_bash_syntax(script):
    r = run("bash", "-n", str(script))
    assert r.returncode == 0, r.stderr


@pytest.mark.parametrize("script", SCRIPTS, ids=IDS)
def test_shellcheck(script):
    assert shutil.which("shellcheck"), "shellcheck is not installed"
    r = run("shellcheck", str(script))
    assert r.returncode == 0, r.stdout
