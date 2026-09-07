#!/usr/bin/env python3
import mmap
import os
import re
import struct
import sys
import syslog

U32 = struct.Struct("<I")
BAR0_LEN = 0x1000000

HERE = os.path.dirname(os.path.abspath(__file__))
CONF = os.path.join(HERE, "gsp-regs.conf")
CONSTANTS = os.path.join(HERE, "..", "common", "constants.yaml")


def load_regs():
    if os.path.isfile(CONF):
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

    try:
        import yaml
    except ImportError:
        sys.exit("error: no %s and PyYAML is unavailable" % CONF)
    with open(CONSTANTS) as f:
        c = yaml.safe_load(f) or {}
    regs = ((c.get("passthrough") or {}).get("gsp_boot_state") or {})
    if not regs:
        sys.exit("error: constants.yaml has no passthrough.gsp_boot_state")
    return [(int(str(regs[n]["addr"]), 16), int(str(regs[n]["value"]), 16), n)
            for n in sorted(regs)]


def open_bar0(dev, writable):
    path = "/sys/bus/pci/devices/%s/resource0" % dev
    if not os.path.exists(path):
        sys.exit("no BAR0 for %s" % dev)
    flags = (os.O_RDWR if writable else os.O_RDONLY) | os.O_SYNC
    prot = mmap.PROT_READ | (mmap.PROT_WRITE if writable else 0)
    fd = os.open(path, flags)
    try:
        return mmap.mmap(fd, BAR0_LEN, mmap.MAP_SHARED, prot)
    finally:
        os.close(fd)


def say(msg, err=False):
    (sys.stderr if err else sys.stdout).write(msg + "\n")
    try:
        syslog.openlog("cmpunlocker", syslog.LOG_PID, syslog.LOG_DAEMON)
        syslog.syslog(syslog.LOG_ERR if err else syslog.LOG_INFO, msg)
    except Exception:
        pass


def main():
    args = sys.argv[1:]
    mode = "restore"
    if args and args[0] in ("show", "restore"):
        mode = args.pop(0)
    if len(args) != 1:
        sys.exit("usage: gsp-restore [show|restore] <pci-address>")
    dev = args[0]
    if not re.fullmatch(r"[0-9a-fA-F]{4}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]", dev):
        sys.exit("bad PCI address: %s" % dev)

    regs = load_regs()
    mm = open_bar0(dev, mode == "restore")
    changed, stuck = [], []
    try:
        boot0 = U32.unpack_from(mm, 0)[0]
        if boot0 == 0xFFFFFFFF:
            state = "unknown"
            try:
                with open("/sys/bus/pci/devices/%s/power_state" % dev) as f:
                    state = f.read().strip()
            except Exception:
                pass
            say("%s: BAR0 reads all ones (power state %s). vfio-pci has idled the "
                "card; load it with disable_idle_d3=1 - see "
                "/etc/modprobe.d/cmpunlocker-vfio.conf" % (dev, state), err=True)
            sys.exit(1)
        if (boot0 >> 20) != 0x170:
            say("%s: not a GA100 (PMC_BOOT_0=0x%08X)" % (dev, boot0), err=True)
            sys.exit(1)

        for addr, want, name in regs:
            before = U32.unpack_from(mm, addr)[0]
            if mode == "show":
                print("  0x%08X  %-34s = 0x%08X %s"
                      % (addr, name, before,
                         "(ok)" if before == want
                         else "(needs restore -> 0x%08X)" % want))
                continue
            if before == want:
                continue
            U32.pack_into(mm, addr, want)
            mm.flush()
            after = U32.unpack_from(mm, addr)[0]
            if after == want:
                changed.append("%s 0x%08X->0x%08X" % (name, before, after))
            else:
                stuck.append(name)
    finally:
        mm.close()

    if mode == "show":
        return

    if stuck:
        say(
            "cmpunlocker: %s cannot clear %s - it is write protected once set.\n"
            "cmpunlocker: this happens when a VM was killed instead of shut down.\n"
            "cmpunlocker: the next VM will not see the GPU until you run:\n"
            "cmpunlocker:   sudo ./tools/passthrough.sh restore %s\n"
            % (dev, ", ".join(stuck), dev), err=True)
    if changed:
        say("cmpunlocker: %s GSP boot state: %s" % (dev, ", ".join(changed)))
    elif not stuck:
        say("cmpunlocker: %s GSP boot state already clean" % dev)
    sys.exit(1 if stuck else 0)


main()
