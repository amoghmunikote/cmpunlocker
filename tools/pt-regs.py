#!/usr/bin/env python3
"""Read or restore the GSP boot-time registers on a CMP 170HX, over BAR0.

Handing an already-unlocked card to a guest means it must not be reset, but a guest's
driver still needs to boot GSP from scratch. These three registers are the difference:
WPR2 must read as down and the ACR version stamp must be clear, or the guest's GSP
boot refuses to proceed. The values are the measured post-reset state.

usage: pt-regs.py show <bdf>
       pt-regs.py restore <bdf>
"""
import io
import mmap
import os
import re
import struct
import sys

U32 = struct.Struct("<I")
BAR0_LEN = 0x1000000
CONSTANTS = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "..", "common", "constants.yaml")


def load_targets():
    """Read the register list from constants.yaml so it stays the single source."""
    try:
        import yaml
    except ImportError:
        sys.exit("error: PyYAML is required (apt install python3-yaml)")
    with io.open(CONSTANTS, encoding="utf-8") as f:
        c = yaml.safe_load(f) or {}
    regs = ((c.get("passthrough") or {}).get("gsp_boot_state") or {})
    if not regs:
        sys.exit("error: constants.yaml has no passthrough.gsp_boot_state block")
    out = []
    for name in sorted(regs):
        r = regs[name]
        out.append((int(str(r["addr"]), 16), int(str(r["value"]), 16), name))
    return out


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("show", "restore"):
        sys.exit(__doc__)
    action, dev = sys.argv[1], sys.argv[2]
    if not re.fullmatch(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]",
                        dev):
        sys.exit("error: expected a full PCI address like 0000:04:00.0")

    targets = load_targets()
    write = action == "restore"
    flags = (os.O_RDWR if write else os.O_RDONLY) | os.O_SYNC
    prot = mmap.PROT_READ | (mmap.PROT_WRITE if write else 0)

    fd = os.open("/sys/bus/pci/devices/%s/resource0" % dev, flags)
    try:
        mm = mmap.mmap(fd, BAR0_LEN, mmap.MAP_SHARED, prot)
    finally:
        os.close(fd)

    rc = 0
    try:
        boot0 = U32.unpack_from(mm, 0)[0]
        if (boot0 >> 20) != 0x170:
            sys.exit("error: %s is not a GA100 (PMC_BOOT_0=0x%08X)" % (dev, boot0))

        for addr, want, name in targets:
            before = U32.unpack_from(mm, addr)[0]
            if not write:
                print("  0x%08X  %-34s = 0x%08X %s"
                      % (addr, name, before,
                         "(ok)" if before == want else "(needs restore -> 0x%08X)" % want))
                continue
            if before == want:
                print("  0x%08X  %-34s already 0x%08X" % (addr, name, want))
                continue
            U32.pack_into(mm, addr, want)
            mm.flush()
            after = U32.unpack_from(mm, addr)[0]
            print("  0x%08X  %-34s 0x%08X -> 0x%08X%s"
                  % (addr, name, before, after,
                     "" if after == want else "   REFUSED"))
            if after != want:
                rc = 1
    finally:
        mm.close()
    sys.exit(rc)


main()
