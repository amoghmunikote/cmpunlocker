import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", ".build", "__pycache__"}


def _files(suffix):
    return sorted(p for p in ROOT.rglob("*" + suffix)
                  if not SKIP_DIRS & set(p.relative_to(ROOT).parts))


def sh_files():
    return _files(".sh")


def py_files():
    return _files(".py")


def rel(path):
    return str(path.relative_to(ROOT))


def versions():
    lines = (ROOT / "driver" / "VERSION").read_text().splitlines()
    return [v for v in lines if re.fullmatch(r"\d+\.\d+\.\d+", v)]


def patch_order(name="PATCH_ORDER"):
    text = (ROOT / "driver" / "build.sh").read_text()
    m = re.search(r"^%s=\(\n(.*?)\n\)" % name, text, re.S | re.M)
    assert m, "%s not found in driver/build.sh" % name
    return m.group(1).split()
