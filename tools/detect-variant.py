#!/usr/bin/env python3
import io
import mmap
import os
import struct
import sys

try:
    import yaml
except ImportError:
    raise SystemExit(0)

BAR0_LEN = 0x1000000
GA100_ARCH = 0x170
U32 = struct.Struct("<I")


def rules(cpath):
    with io.open(cpath, encoding="utf-8") as f:
        c = yaml.safe_load(f) or {}
    out = []
    for name, p in sorted((c.get("profiles") or {}).items()):
        det = (p or {}).get("detect") or {}
        reg, val = det.get("register"), det.get("value")
        if reg and val:
            out.append((name, int(str(reg), 16), int(str(val), 16)))
    return out


def probe(bdf, regs):
    path = "/sys/bus/pci/devices/%s/resource0" % bdf
    fd = os.open(path, os.O_RDONLY | os.O_SYNC)
    try:
        mm = mmap.mmap(fd, BAR0_LEN, mmap.MAP_SHARED, mmap.PROT_READ)
    finally:
        os.close(fd)
    try:
        boot0 = U32.unpack_from(mm, 0)[0]
        if boot0 == 0xFFFFFFFF or (boot0 >> 20) != GA100_ARCH:
            return None
        return dict((r, U32.unpack_from(mm, r)[0]) for r in regs)
    finally:
        mm.close()


def main():
    if len(sys.argv) < 3:
        raise SystemExit(0)
    rs = rules(sys.argv[1])
    if not rs:
        return
    regs = sorted(set(r for _, r, _ in rs))
    for bdf in sys.argv[2:]:
        try:
            vals = probe(bdf, regs)
        except Exception:
            continue
        if not vals:
            continue
        for name, reg, want in rs:
            if vals.get(reg) == want:
                print("%s %s" % (bdf, name))
                break


main()
