# Kernel updates and recovery

The installer saves an offline build payload under `/var/lib/cmpunlocker/payload`
and the **actual installed configuration** in `/etc/cmpunlocker/build.json`.
Moving or deleting your Git checkout does not affect future rebuilds. It saves
the NVIDIA version, memory profile/inventory, P2P transport, Gen2 choice and
whether the passthrough helper needs rebuilding. It never bakes in an overclock.

On Ubuntu/Debian, both `/etc/kernel/postinst.d/zz-cmpunlocker` and
`/etc/kernel/header_postinst.d/zz-cmpunlocker` rebuild for the kernel being
installed, even when it is not running yet. The second hook handles headers
arriving after the kernel. Kernel-install and Arch header hooks are also
provided; apt package holds are currently the only automated package pinning.

`/etc/depmod.d/cmpunlocker.conf` gives our modules priority over stock/DKMS
modules. Module options and the nouveau blacklist are written before initramfs
is rebuilt. Builds and removals never reload the live NVIDIA driver.

## Commands

```bash
sudo python3 /usr/lib/cmpunlocker/manage.py status
sudo python3 /usr/lib/cmpunlocker/manage.py rebuild
sudo python3 /usr/lib/cmpunlocker/manage.py rebuild <new-kernel-version>
systemctl status cmpunlocker-check.service
sudo journalctl -u cmpunlocker-check.service -b
```

Logs are `/var/log/cmpunlocker/rebuild-<kernel-version>.log`. Failures leave a
marker in `/var/lib/cmpunlocker/state/failed-<kernel-version>` and manual rebuilds
return a nonzero exit status. Ubuntu hooks report the error but allow dpkg to
finish, so the header hook can retry. Do not reboot into a new kernel until its
build succeeds. The boot service checks installed module identity/selection
and, in BAR1 mode, BAR1 assignments. It reports failures without trying to swap
the driver in use. `verify.sh` and the CUDA content test remain the runtime checks.

Reinstalling with a different P2P/Gen2 mode updates the running kernel's on-disk
modules and the shared boot options. Rebuild any older kernel you intend to use
with `manage.py rebuild <version>` so its modules match those options; stale
builds are flagged by the boot check. `manage.py rebuild-all` rebuilds every
installed kernel that has headers.

**The Linux PCI patches are separate.** Rebuilding NVIDIA for a stock replacement
kernel does not carry forward `kernel-patches/`. In BAR1 mode, retain your working
kernel and validate full BAR1 on every card after booting a new one. If allocations
shrink, use the working kernel, port the Linux patches, or test mailbox mode.
Neither a successful driver build nor a passing boot service proves P2P routing.

## NVIDIA package holds

On Ubuntu the installer holds installed NVIDIA packages, including versioned
GSP firmware, to keep the kernel driver, libraries and firmware matched.
Independent `nvidia-gpu-firmware`/`firmware-nvidia` packages are excluded.
Only holds created by cmpunlocker are recorded and removed; holds you already
had are preserved. The Linux kernel and unrelated system packages are not held.

```bash
sudo python3 /usr/lib/cmpunlocker/manage.py unpin
# Upgrade the matching NVIDIA open-driver/userspace packages to a version in
# driver/VERSION, then rerun this checkout's install.sh with your chosen options.
sudo python3 /usr/lib/cmpunlocker/manage.py pin
```

Driver upgrades are deliberate maintenance: inspect `driver/VERSION` before
upgrading, and reinstall the unlock for that version before cold booting.

`install.sh --no-pin` releases cmpunlocker's holds and disables creating new
ones for that installation. `--no-persist` removes the automatic hooks/service;
the saved payload remains available for manual rebuilds. These options can be
combined with `--p2p=bar1`, `--p2p=mailbox`, `--no-gen2`, etc.

`remove.sh --yes` removes hooks, configuration, saved build sources and our
package holds before restoring stock modules. It preserves maintenance logs
and any custom `/var/lib/cmpunlocker/dmem.bin`. That optional boot-payload override
now uses a private directory rather than a distro firmware directory; normal
installs use the built-in payload and need no `dmem.bin` file.

## Port notes

Adapted from [asm64-hooligan/cmpunlocker at dea1e84](https://github.com/asm64-hooligan/cmpunlocker/tree/dea1e8487110918a9135f41863ac33a1f3effacc/persist).
The local version preserves all our build flags, copies the shared tools/constants,
retries on Ubuntu header installation, tracks module hashes, and preserves existing
apt holds. It does not import live reloads or boot-time driver replacement.
