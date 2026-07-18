"""CI tests for cmpunlocker 610 patch-only layout."""

from __future__ import annotations

import os
import re
import subprocess
import tarfile
import urllib.request
from pathlib import Path

import pytest
import yaml

REPO = Path(__file__).resolve().parents[1]
DRIVER = REPO / "driver"
PATCHES = DRIVER / "patches"
VERSIONS = [
    line.strip()
    for line in (DRIVER / "VERSION").read_text(encoding="utf-8").splitlines()
    if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", line.strip())
]
CONSTANTS = REPO / "common" / "constants.yaml"


def test_version_file():
    assert VERSIONS == ["610.43.03", "610.43.02"]


def test_constants_yaml_profiles():
    data = yaml.safe_load(CONSTANTS.read_text(encoding="utf-8"))
    assert data["driver_versions"] == VERSIONS
    assert "20c2" in data["gpu"]["device_ids"]
    assert set(data["profiles"]) == {"8gb", "10gb"}
    assert data["profiles"]["8gb"]["unlocked_mib"] == 65536
    assert data["profiles"]["8gb"]["cfg1"].lower() == "0x02779000"
    assert data["profiles"]["10gb"]["unlocked_mib"] == 40960
    assert data["profiles"]["10gb"]["cfg1"].lower() == "0x02669000"
    assert data["profiles"]["10gb"]["lmr"].lower() == "0x0000028a"


def test_patches_exist_and_ordered():
    patches = sorted(PATCHES.glob("*.patch"))
    assert len(patches) >= 6
    names = [p.name for p in patches]
    assert names[0].startswith("0001-")
    for p in patches:
        text = p.read_text(encoding="utf-8", errors="replace")
        assert text.startswith("--- ") or "--- a/" in text[:200]
        assert "+++" in text


def test_scripts_are_executable():
    for rel in ("install.sh", "remove.sh", "driver/build.sh"):
        path = REPO / rel
        assert path.is_file()
        assert os.access(path, os.X_OK), f"{rel} must be executable"


def test_install_help_mentions_profiles():
    result = subprocess.run(
        ["bash", str(REPO / "install.sh"), "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0
    assert "--profile=8gb" in result.stdout
    assert "--profile=10gb" in result.stdout


def _extract_stock(tmp_path: Path, version: str) -> Path:
    cache_dir = Path(os.environ.get("CMPUNLOCKER_BUILD_DIR", DRIVER / ".build"))
    cache_dir.mkdir(parents=True, exist_ok=True)
    tarball = cache_dir / f"open-gpu-kernel-modules-{version}.tar.gz"
    url = (
        "https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/"
        f"{version}.tar.gz"
    )
    if not tarball.is_file():
        urllib.request.urlretrieve(url, tarball)

    extract_root = tmp_path / f"src-{version}"
    extract_root.mkdir()
    with tarfile.open(tarball, "r:gz") as tar:
        tar.extractall(extract_root, filter="data")

    matches = list(extract_root.glob(f"open-gpu-kernel-modules-{version}*"))
    assert matches, f"extracted source tree not found for {version}"
    return matches[0]


def _apply_patches(src: Path) -> None:
    for patch in sorted(PATCHES.glob("*.patch")):
        result = subprocess.run(
            ["patch", "-p1", "-i", str(patch)],
            cwd=src,
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, (
            f"apply failed for {patch.name} on {src.name}:\n"
            f"{result.stdout}\n{result.stderr}"
        )


def _rewrite_geometry(gsp_c: Path, cfg1: str, lmr: str, fb: str, label: str) -> None:
    text = gsp_c.read_text()
    text2, n1 = re.subn(
        r"(NvU32 cfg1Value = )0x[0-9A-Fa-f]+(U;)",
        rf"\g<1>{cfg1}\g<2>",
        text,
        count=1,
    )
    text2, n2 = re.subn(
        r"(NvU32 lmrValue\s*=\s*)0x[0-9A-Fa-f]+(U;)",
        rf"\g<1>{lmr}\g<2>",
        text2,
        count=1,
    )
    text2, n3 = re.subn(
        r"(NvU64 targetFbBytes = )0x[0-9A-Fa-f]+ULL;\s*/\*[^*]*\*/",
        rf"\g<1>{fb}ULL;  /* {label} */",
        text2,
        count=1,
    )
    assert (n1, n2, n3) == (1, 1, 1)
    gsp_c.write_text(text2)


@pytest.mark.parametrize("version", VERSIONS)
def test_patches_apply_to_stock_tree(tmp_path, version):
    src = _extract_stock(tmp_path, version)
    _apply_patches(src)
    gsp = src / "src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
    text = gsp.read_text()
    assert "0x02779000" in text
    assert "0x0000001000000000" in text


@pytest.mark.parametrize("version", VERSIONS)
def test_10gb_geometry_rewrite(tmp_path, version):
    src = _extract_stock(tmp_path, version)
    _apply_patches(src)
    gsp = src / "src/nvidia/src/kernel/gpu/gsp/kernel_gsp.c"
    _rewrite_geometry(
        gsp,
        "0x02669000",
        "0x0000028A",
        "0x0000000A00000000",
        "40GB",
    )
    text = gsp.read_text()
    assert "cfg1Value = 0x02669000U" in text
    assert "lmrValue  = 0x0000028AU" in text or "lmrValue = 0x0000028AU" in text
    assert "0x0000000A00000000ULL" in text
    assert "40GB" in text
    assert "0x02779000" not in text
