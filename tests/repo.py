import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SKIP_DIRS = {".git", ".build", ".venv", "__pycache__"}


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


def patch_order(p2p=False, gen2=True):
    text = (ROOT / "driver" / "build.sh").read_text()
    arrays = {name: body.split() for name, body in re.findall(
        r"^((?:[A-Z0-9]+_)*PATCH_ORDER)=\(\n(.*?)\n\)", text, re.S | re.M)}
    order = list(arrays["PATCH_ORDER"])
    if gen2:
        order += arrays["GEN2_PATCH_ORDER"]
    mode = "bar1" if p2p is True else "off" if p2p is False else p2p
    if mode != "off":
        order += arrays["P2P_COMMON_PATCH_ORDER"]
        order += arrays["P2P_" + mode.upper() + "_PATCH_ORDER"]
    return order
