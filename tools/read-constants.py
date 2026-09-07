#!/usr/bin/env python3
import io
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("error: PyYAML is required to read constants.yaml "
             "(apt install python3-yaml)")

REQUIRED_PROFILE_KEYS = ("cfg1", "lmr", "fb_bytes", "label", "geometry_rewrite")


def hex_forms(text):
    m = re.fullmatch(r"0[xX]([0-9a-fA-F]+)", text.strip())
    if not m:
        return None
    digits = m.group(1).lower().lstrip("0") or "0"
    forms = {digits, digits.zfill(16), digits.zfill(8), digits.zfill(4)}
    return {"0x" + f for f in forms}


def present(blob_lower, value):
    forms = hex_forms(value)
    if forms is None:
        return False
    return any(re.search(re.escape(f) + r"[ul]*\b", blob_lower)
               for f in forms)


def read_expected_mib(lib_sh):
    text = io.open(lib_sh, encoding="utf-8").read()
    m = re.search(r"expected_mib_for_profile\(\)\s*\{(.*?)\n\}", text, re.S)
    if not m:
        sys.exit("error: expected_mib_for_profile not found in %s" % lib_sh)
    return dict(re.findall(r'(\w+)\)\s*echo\s*"(\d+)"', m.group(1)))


def read_patch_order(build_sh):
    text = io.open(build_sh, encoding="utf-8").read()
    m = re.search(r"PATCH_ORDER=\(\n(.*?)\n\)", text, re.S)
    if not m:
        sys.exit("error: PATCH_ORDER not found in %s" % build_sh)
    return [l.strip() for l in m.group(1).splitlines() if l.strip()]


def main():
    if len(sys.argv) != 5:
        sys.exit("usage: read-constants.py <constants.yaml> <patch-dir> "
                 "<build.sh> <profile>")
    cpath, patch_dir, build_sh, profile = sys.argv[1:5]

    with io.open(cpath, encoding="utf-8") as f:
        c = yaml.safe_load(f)

    profiles = c.get("profiles") or {}
    if profile not in profiles:
        sys.exit("error: unknown profile %r; constants.yaml defines %s"
                 % (profile, ", ".join(sorted(profiles))))
    p = profiles[profile]
    missing = [k for k in REQUIRED_PROFILE_KEYS if k not in p]
    if missing:
        sys.exit("error: profile %r is missing: %s"
                 % (profile, ", ".join(missing)))

    unlocks = c.get("unlocks") or {}
    if not unlocks:
        sys.exit("error: constants.yaml declares no unlocks")

    order = read_patch_order(build_sh)
    declared = {u["patch"] for u in unlocks.values() if u.get("patch")}

    problems = []
    for name in sorted(set(order) - declared):
        problems.append("patch %s is built but not declared in constants.yaml"
                        % name)
    for name in sorted(declared - set(order)):
        problems.append("constants.yaml declares %s but it is not in "
                        "PATCH_ORDER" % name)

    lib_sh = os.path.join(os.path.dirname(os.path.abspath(cpath)), "lib.sh")
    if not os.path.isfile(lib_sh):
        problems.append("missing %s" % lib_sh)
        lib_mib = {}
    else:
        lib_mib = read_expected_mib(lib_sh)
    for pname in sorted(c.get("gpu", {}).get("device_ids") or {}):
        if pname not in profiles:
            problems.append("device_ids lists %s but profiles does not"
                            % pname)
            continue
        want = str(profiles[pname].get("unlocked_mib", ""))
        got = lib_mib.get(pname, "")
        if got != want:
            problems.append("profile %s: constants say unlocked_mib=%s but "
                            "lib.sh expected_mib_for_profile says %r"
                            % (pname, want, got))

    cache = {}
    for uname in sorted(unlocks):
        u = unlocks[uname] or {}
        pname = u.get("patch")
        if not pname:
            problems.append("unlock %s has no patch" % uname)
            continue
        ppath = os.path.join(patch_dir, pname)
        if not os.path.isfile(ppath):
            problems.append("unlock %s: missing %s" % (uname, ppath))
            continue
        if ppath not in cache:
            cache[ppath] = io.open(ppath, encoding="utf-8",
                                   errors="replace").read().lower()
        blob = cache[ppath]
        for rname, r in sorted((u.get("registers") or {}).items()):
            addr = r.get("addr")
            if not addr or not present(blob, addr):
                problems.append("unlock %s: %s addr %s not found in %s"
                                % (uname, rname, addr, pname))
                continue
            val = r.get("value")
            if val and not present(blob, val):
                problems.append("unlock %s: %s value %s not found in %s"
                                % (uname, rname, val, pname))

    for pname in sorted(profiles):
        det = (profiles[pname] or {}).get("detect")
        if not det:
            continue
        dpatch = det.get("patch")
        dpath = os.path.join(patch_dir, dpatch or "")
        if not dpatch or not os.path.isfile(dpath):
            problems.append("profile %s: detect patch %s missing"
                            % (pname, dpatch))
            continue
        if dpath not in cache:
            cache[dpath] = io.open(dpath, encoding="utf-8",
                                   errors="replace").read().lower()
        blob = cache[dpath]
        checks = [(k, v) for k, v in sorted(det.items()) if k != "patch"]
        checks += [(k, profiles[pname][k])
                   for k in ("cfg1", "lmr", "fb_bytes")]
        for kname, val in checks:
            if not present(blob, str(val)):
                problems.append("profile %s: %s %s not found in %s"
                                % (pname, kname, val, dpatch))

    if problems:
        sys.exit("error: common/constants.yaml does not match the patches:\n  "
                 + "\n  ".join(problems))

    out = [
        ("CFG1", p["cfg1"]),
        ("LMR", p["lmr"]),
        ("FB_BYTES", p["fb_bytes"]),
        ("UNLOCK_LABEL", p["label"]),
        ("SKIP_GEOMETRY_REWRITE", "0" if p["geometry_rewrite"] else "1"),
        ("PROFILE_STOCK_MIB", str(p.get("stock_mib", ""))),
        ("PROFILE_UNLOCKED_MIB", str(p.get("unlocked_mib", ""))),
        ("CONSTANTS_UNLOCK_COUNT", str(len(unlocks))),
    ]
    for k, v in out:
        print("%s=%s" % (k, "'" + str(v).replace("'", "'\\''") + "'"))


if __name__ == "__main__":
    main()
