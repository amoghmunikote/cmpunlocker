# VM passthrough (VFIO / Proxmox)

The unlock the host applies survives into a guest. The VM needs nothing but a stock
NVIDIA driver — no cmpunlocker inside the guest, no patched modules, no extra packages.

```bash
sudo ./install.sh                                  # unlock the cards as usual
sudo ./tools/passthrough.sh prepare 0000:04:00.0   # hand one to vfio-pci, unlock intact
```

Then pass the card to a VM the normal way. Measured in a guest running only
`nvidia-driver-open` 610.57.04, with cmpunlocker absent from the VM entirely:

```
nvidia-smi:  NVIDIA Graphics Device, 32768 MiB
CUDA:        31.58 GiB, 70 SMs
             allocated 31 x 1 GiB, pattern written and read back every 4 KB
             verify: 31 of 31 chunks correct
```

Both the memory unlock and the full 70-SM unlock carry through.

## Why this needs a tool at all

A GPU handed to `vfio-pci` gets reset, and the reset puts every unlocked register back
to stock — `CFG1` to `0x22559000`, 512 MB per FBPA, and the PLMs re-locked. QEMU does
it at attach, before any guest code runs. That was confirmed three ways: a guest with
no NVIDIA driver installed at all, a guest started paused so its CPU never executed,
and a QMP hotplug into an already-running guest. All three came back stock.

Emptying `reset_method` is not enough. QEMU's `vfio_pci_reset()` tries FLR, then a
bus-level hot reset, then a PM reset, and the bus reset goes through the parent bridge
where a per-device setting has no say. The trace shows it plainly:

```
vfio_pci_hot_reset  (0000:04:00.0) one
vfio_pci_hot_reset_has_dep_devices 0000:04:00.0: hot reset dependent devices:
vfio_pci_hot_reset_result 0000:04:00.0 hot reset: Success
```

But QEMU only *tries*. When all three paths fail it attaches the device without
resetting it. So the job is to make all three fail:

- `reset_method` emptied kills the FLR and the PM reset. Note `echo none` is rejected;
  the kernel wants an empty write, so `printf ' '` is the form that takes.
- `driver/passthrough/cmp_no_bus_reset.c` sets `PCI_DEV_FLAGS_NO_BUS_RESET` on the
  card, which makes `pci_bus_resettable()` refuse, so the hot reset fails too. That
  flag has no sysfs control, which is why it takes a small module.

With both in place the `hot reset: Success` line disappears and the card keeps
everything the host gave it.

## The other half: letting the guest still boot GSP

Not resetting the card preserves the unlock, but a guest's driver still has to boot
GSP from scratch, and it refuses if the previous owner left GSP state behind:

```
NVRM: GPU0 _kgspBootGspRm: unexpected WPR2 already up, cannot proceed with booting GSP
```

Clear WPR2 but leave the ACR version stamp set and it fails one step later instead,
with Booter mailbox `0x29`, `ACR_ERROR_BINARY_SEQUENCE_MISMATCH` — the load binary
requires `ACR_BINARY_VERSION` in `NV_PGC6_BSI_SECURE_SCRATCH_14` to be zero because it
expects to be the first ACR binary to run.

So `prepare` also restores three registers to their measured post-reset values, which
`tools/pt-regs.py` reads from `common/constants.yaml`:

| register | address | post-reset value |
|---|---|---|
| `NV_PFB_PRI_MMU_WPR2_ADDR_LO` | `0x001FA824` | `0x1FFFFE00` (not zero) |
| `NV_PFB_PRI_MMU_WPR2_ADDR_HI` | `0x001FA828` | `0x00000000` |
| `NV_PGC6_BSI_SECURE_SCRATCH_14` | `0x001180F8` | `0x00000000` |

In practice the host driver's clean unload already leaves them that way; `prepare`
checks and reports rather than blindly writing.

## Shut guests down cleanly

On a clean guest shutdown the guest's own driver unloads, runs Booter Unload, and puts
all three registers back by itself. The card is then ready for the next VM start with
**nothing to do on the host** — verified by running two VMs back to back, both seeing
32768 MiB, with no host intervention between them.

A killed or hard-reset VM does not get that chance and leaves WPR2 up and the stamp
set. The stamp is write-protected, so it cannot simply be poked back; that card needs

```bash
sudo ./tools/passthrough.sh restore 0000:04:00.0
sudo ./tools/passthrough.sh prepare 0000:04:00.0
```

`status` shows which state a card is in.

## Things that will bite you

- **Never unbind a single device from `nvidia` while the driver still holds it.** It
  logs `Attempting to remove device ... with non-zero usage count!`, the following
  `vfio-pci` bind hangs in D state, and recovery needs a cold power cycle — an FLR is
  not enough. `prepare` always unloads the whole nvidia stack instead, which is why
  every GPU on the host blips offline for a few seconds.
- Stop `nvidia-persistenced` first or the `rmmod` fails; `prepare` does this.
- Do not FLR a card whose GSP is running. Same wedge, same cold-cycle recovery.

## Reproducing the measurements

The register probe reads BAR0 read-only through
`/sys/bus/pci/devices/<bdf>/resource0` and needs no driver, so it works on the host, on
a vfio-bound card, and inside a guest:

```
FBPA_CFG1              0x009A0204
FBPA_CSTATUS           0x009A020C   RAMAMOUNT 16:0 = MB per FBPA
MMU_LOCAL_MEMORY_RANGE 0x00100CE0
OPT_FBPA_DISABLE       0x00820368

total FB = CSTATUS.RAMAMOUNT * (24 - popcount(OPT_FBPA_DISABLE))
```

Booter mailbox codes are `ACR_STATUS` values from `rmlsfm.h`, written to MAILBOX0 by
`acr_helper_functions_tu10x.c`. `0x31` is `ACR_ERROR_BIN_STARTED_BUT_NOT_FINISHED`,
the expected signature of the payload hijack; `0x15` is `ACR_ERROR_FLCN_REG_ACCESS`;
`0x29` is `ACR_ERROR_BINARY_SEQUENCE_MISMATCH`.

```
dmesg | grep -oE "Booter failed with non-zero error code: 0x[0-9a-f]+" | sort | uniq -c
```

## Running cmpunlocker inside the guest instead

Don't — it does not work, and this tool exists because of that. With cmpunlocker's
driver in the guest the GPU does not come up at all: the unlock's register writes land,
but the Booter Load that follows returns `0x15` on a clean card and GSP-RM never boots.
Bare metal returns `0x31` on all 296 invocations; a guest returns `0x15` on most of
them. Unlocking on the host and passing the card through is the supported path.
