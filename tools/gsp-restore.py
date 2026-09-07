#!/usr/bin/env python3
"""Put a CMP 170HX's GSP boot-time registers back, without resetting the card.

Run from udev when a card binds to vfio-pci. The card keeps everything cmpunlocker
gave it, but a guest driver still needs to boot GSP from scratch, and it refuses if
the previous owner left WPR2 up or the ACR version stamp set.

Register list comes from gsp-regs.conf, which install.sh generates from
common/constants.yaml, so the values stay defined in exactly one place.
"""
import mmap
import os
import re
import struct
import sys

U32 = struct.Struct("<I")
BAR0_LEN = 0x1000000
CONF = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gsp-regs.conf")


def load_regs():
    out = []
    with open(CONF) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            out.append((int(parts[0], 16), int(parts[1], 16),
                        parts[2] if len(parts) > 2 else ""))
    return out


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: gsp-restore <pci-address>")
    dev = sys.argv[1]
    if not re.fullmatch(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]", dev):
        sys.exit("bad PCI address: %s" % dev)

    path = "/sys/bus/pci/devices/%s/resource0" % dev
    if not os.path.exists(path):
        sys.exit("no BAR0 for %s" % dev)

    fd = os.open(path, os.O_RDWR | os.O_SYNC)
    try:
        mm = mmap.mmap(fd, BAR0_LEN, mmap.MAP_SHARED,
                       mmap.PROT_READ | mmap.PROT_WRITE)
    finally:
        os.close(fd)

    changed = []
    stuck = []
    try:
        boot0 = U32.unpack_from(mm, 0)[0]
        if (boot0 >> 20) != 0x170:
            sys.exit("%s: not a GA100 (PMC_BOOT_0=0x%08X)" % (dev, boot0))
        for addr, want, name in load_regs():
            before = U32.unpack_from(mm, addr)[0]
            if before == want:
                continue
            U32.pack_into(mm, addr, want)
            mm.flush()
            after = U32.unpack_from(mm, addr)[0]
            if after == want:
                changed.append("%s 0x%08X->0x%08X" % (name or hex(addr),
                                                      before, after))
            else:
                stuck.append(name or hex(addr))
    finally:
        mm.close()

    if stuck:
        sys.stderr.write(
            "cmpunlocker: %s cannot clear %s - it is write protected once set.\n"
            "cmpunlocker: this happens when a VM was killed instead of shut down.\n"
            "cmpunlocker: the next VM will not see the GPU until you run:\n"
            "cmpunlocker:   sudo ./tools/passthrough.sh restore %s\n"
            % (dev, ", ".join(stuck), dev))
    if changed:
        print("cmpunlocker: %s GSP boot state: %s" % (dev, ", ".join(changed)))
    elif not stuck:
        print("cmpunlocker: %s GSP boot state already clean" % dev)


main()
