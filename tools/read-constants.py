#!/usr/bin/env python3
"""
read-constants.py -- read common/constants.yaml for driver/build.sh, and check
that it has not gone stale.

Emits shell assignments on stdout for the requested card profile, so the YAML is
the single source of truth for the geometry the build rewrites rather than a
second copy of values hardcoded in build.sh.

It also verifies every address under registers: still appears somewhere in
driver/patches/*.patch. That is the part that keeps the file honest: if a patch
stops using a constant, or an address changes, the build fails here instead of
the YAML quietly describing a driver that no longer exists.

    read-constants.py <constants.yaml> <patch-dir> <profile>
"""
import glob
import os
import re
import sys

try:
    import yaml
except ImportError:
    sys.exit("error: PyYAML is required to read constants.yaml "
             "(apt install python3-yaml)")


def walk_addrs(node, path=()):
    """Yield (dotted-name, addr) for every mapping that carries an 'addr'."""
    if isinstance(node, dict):
        if "addr" in node and isinstance(node["addr"], str):
            yield ".".join(path), node["addr"]
        for k, v in node.items():
            yield from walk_addrs(v, path + (str(k),))


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__.strip())
    cpath, patch_dir, profile = sys.argv[1:4]

    with open(cpath, encoding="utf-8") as f:
        c = yaml.safe_load(f)

    profiles = c.get("profiles") or {}
    if profile not in profiles:
        sys.exit("error: unknown profile %r; constants.yaml defines %s"
                 % (profile, ", ".join(sorted(profiles))))
    p = profiles[profile]

    required = ("cfg1", "lmr", "fb_bytes", "label", "geometry_rewrite")
    missing = [k for k in required if k not in p]
    if missing:
        sys.exit("error: profile %r in constants.yaml is missing: %s"
                 % (profile, ", ".join(missing)))

    # Staleness check: every documented address must still be in a patch.
    patches = sorted(glob.glob(os.path.join(patch_dir, "*.patch")))
    if not patches:
        sys.exit("error: no patches found in %s" % patch_dir)
    blob = ""
    for f in patches:
        with open(f, encoding="utf-8", errors="replace") as fh:
            blob += fh.read()
    blob_l = blob.lower()

    stale = []
    for name, addr in walk_addrs(c.get("registers") or {}):
        a = addr.lower()
        # Patches write these as 0x0082381cU; match with or without the suffix,
        # and tolerate the odd 0x0082381C casing difference.
        if not re.search(re.escape(a) + r"u?\b", blob_l):
            stale.append("%s (%s)" % (name, addr))
    if stale:
        sys.exit("error: common/constants.yaml is out of date; these addresses "
                 "no longer appear in any patch:\n  " + "\n  ".join(stale))

    out = {
        "CFG1": p["cfg1"],
        "LMR": p["lmr"],
        "FB_BYTES": p["fb_bytes"],
        "UNLOCK_LABEL": p["label"],
        "SKIP_GEOMETRY_REWRITE": "0" if p["geometry_rewrite"] else "1",
        "PROFILE_STOCK_MIB": str(p.get("stock_mib", "")),
        "PROFILE_UNLOCKED_MIB": str(p.get("unlocked_mib", "")),
    }
    for k, v in out.items():
        print("%s=%s" % (k, "'" + str(v).replace("'", "'\\''") + "'"))


if __name__ == "__main__":
    main()
