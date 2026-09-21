#!/usr/bin/env python3
"""Read-only check of Linux BAR1 assignments before enabling static BAR1 P2P."""
import argparse
import pathlib
import sys

BAR1_BYTES = 64 * 1024 ** 3


def check(root):
    found = 0
    failures = 0
    for device in sorted(root.iterdir()):
        try:
            vendor = int((device / "vendor").read_text().strip(), 16)
            devid = int((device / "device").read_text().strip(), 16)
        except (OSError, ValueError):
            continue
        if vendor != 0x10DE or devid not in (0x20C2, 0x2082):
            continue
        found += 1
        try:
            bar1 = (device / "resource").read_text().splitlines()[1]
            start, end, flags = (int(value, 16) for value in bar1.split())
            size = end - start + 1 if start and end >= start and flags & 0x200 else 0
        except (OSError, ValueError, IndexError):
            size = 0
        ready = size >= BAR1_BYTES
        print(f"{device.name}: BAR1 {size // (1024 ** 2)} MiB — {'OK' if ready else 'NEEDS 64 GiB'}")
        failures += not ready
    if not found:
        print("No supported CMP GPUs found in PCI sysfs", file=sys.stderr)
        return 1
    if failures:
        print("Enable Above 4G Decoding and allocate a full BAR1 on every CMP GPU first. "
              "See kernel-patches/README.md and docs/P2P.md.", file=sys.stderr)
    return int(failures != 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sysfs-root", type=pathlib.Path, default=pathlib.Path("/sys/bus/pci/devices"))
    args = parser.parse_args()
    if not args.sysfs_root.is_dir():
        parser.error("PCI sysfs directory does not exist; run this on the Linux GPU host")
    return check(args.sysfs_root)


if __name__ == "__main__":
    sys.exit(main())
