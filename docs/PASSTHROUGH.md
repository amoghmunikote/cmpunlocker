# VM passthrough (VFIO / Proxmox)

Short version: **the unlock does not currently survive PCI passthrough**, and the
reason is not something cmpunlocker can configure around. This page records what
was measured so nobody has to rediscover it.

## Test rig

Everything below was measured, not inferred.

| | |
|---|---|
| Host | Ubuntu 24.04, kernel 6.8.0-138-generic, `intel_iommu=on iommu=pt pci=realloc=on` |
| GPU | CMP 170HX `10de:20c2`, single-rank (ES) variant, `OPT_FBPA_DISABLE=0x00000CF3` |
| IOMMU group | the card is alone in its group, so nothing else constrains reset |
| Hypervisor | QEMU 8.2.2, q35 + OVMF, `-device vfio-pci,host=...` |
| Guest | Ubuntu 24.04, `nvidia-driver-open` 610.57.04 from NVIDIA's CUDA repo |

## What works: the unlock survives the handoff to vfio-pci

With reset disabled and a **clean full module unload**, the card sits on `vfio-pci`
still carrying everything cmpunlocker did:

```
systemctl stop nvidia-persistenced
printf " " > /sys/bus/pci/devices/0000:04:00.0/reset_method   # disables flr AND bus
rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia
modprobe vfio-pci disable_idle_d3=1
echo vfio-pci > /sys/bus/pci/devices/0000:04:00.0/driver_override
echo 0000:04:00.0 > /sys/bus/pci/drivers/vfio-pci/bind
```

Reading BAR0 from the host afterwards, with the card bound to `vfio-pci`:

```
FBPA_CFG1              = 0x02779000
FBPA_CSTATUS           = 2048 MB/FBPA   -> 16 live FBPAs = 32768 MB
MMU_LOCAL_MEMORY_RANGE = 0x0000020A
FBPA_PLM / WPR_PLM / FEAT_PLM = 0xFFFFFFFF   (open)
```

Two details that matter and cost a wedged card each to learn:

- `echo none > reset_method` is **rejected**. The kernel wants an empty write;
  `printf " "` is the form that takes.
- Use a full `rmmod` of the nvidia stack, **not** a per-device unbind. Force-unbinding
  one device while the driver still holds it logs
  `Attempting to remove device ... with non-zero usage count!`, and the subsequent
  `vfio-pci` bind hangs in D state. Recovering that needs a cold power cycle; an FLR
  is not enough.

## What breaks: QEMU resets the card at attach

The moment QEMU attaches the device, the card is back to stock:

```
FBPA_CFG1              = 0x22559000     (native)
FBPA_CSTATUS           = 512 MB/FBPA    -> 8192 MB
MMU_LOCAL_MEMORY_RANGE = 0x00000208
FBPA_PLM = 0xFFFFFF8F   WPR_PLM = 0x0004CB8F   FEAT_PLM = 0xFFFFFF8F   (re-locked)
```

The PLMs re-locking is the tell: this is a full chip reset, not a config-space touch.

This was pinned down three independent ways, so it is not guesswork:

1. **Guest with no NVIDIA driver installed at all** (fresh cloud image) — still reset.
   So it is not the guest driver re-running devinit.
2. **QEMU started paused (`-S`), guest CPU never executed** — already reset. So it is
   not OVMF and not the guest kernel.
3. **Hot-plugged into an already-running guest** via QMP `device_add` — also reset.

At the time of the reset `reset_method` was empty, `disable_idle_d3=Y` and
`power_state=D0`, so it is neither FLR nor a D3 transition. QEMU falls back to a
**bus-level hot reset** through the parent bridge, which a per-device `reset_method`
cannot block, and which it is allowed to do precisely because the card is alone in
its IOMMU group.

**Consequence: nothing applied on the host can reach the guest.** Installing
cmpunlocker on the host and passing the card through does not transfer the unlock.

## What also breaks: running cmpunlocker inside the guest

The other direction fails too, so this is not simply a matter of moving the unlock
into the VM.

Passthrough itself is fine — the **stock** driver in the guest gives a working GPU at
its locked 8192 MiB. With cmpunlocker's driver the GPU does not come up at all:

```
NVRM: GPU0 RmInitAdapter: Cannot initialize GSP firmware RM
NVRM: GPU 0000:00:02.0: RmInitAdapter failed! (0x62:0xffff:2119)
$ nvidia-smi
No devices were found
```

The unlock's register writes do land — verified live from inside the guest:
`CFG1=0x02779000`, `CSTATUS=2048 MB/FBPA`, PLMs open, 32768 MB. What fails is the
ordinary Booter Load that follows, which returns a non-zero SEC2 mailbox and
therefore `NV_ERR_GENERIC`, and without it GSP-RM never boots.

The mailbox codes say why, and the resman source names them. `rmlsfm.h` defines
`enum _ACR_STATUS`, and `acr_helper_functions_tu10x.c` writes that status straight
into MAILBOX0:

| code | name |
|---|---|
| `0x31` | `ACR_ERROR_BIN_STARTED_BUT_NOT_FINISHED` |
| `0x15` | `ACR_ERROR_FLCN_REG_ACCESS` |
| `0x29` | `ACR_ERROR_BINARY_SEQUENCE_MISMATCH` |

`0x31` is the payload hijack working: the binary starts, is diverted, and never
finishes. On bare metal that is the result of all 296 invocations.

`0x29` is the blocker, and `acrWriteAcrVersionToBsiSecureScratch_TU10X` explains it.
The ACR load binary requires `ACR_BINARY_VERSION` in
`NV_PGC6_BSI_SECURE_SCRATCH_14` (`0x001180F8`, bits 23:20) to be zero, because it
expects to be the first ACR binary to run — and it **stamps its own version there**
on the way through. Only the unload binary clears that stamp; the source comment says
unload "wipes out the version ... to make the next ACR load have a clean slate".

So **Booter Load is one-shot**. Once the stamp is set, every later load returns `0x29`
regardless of how many times it is retried. That is why a first attempt at a simple
16-deep retry loop failed 16 times out of 16 — retrying cannot clear the stamp.

On bare metal the hijack diverts the binary *before* it reaches the stamp, so the
scratch stays zero and every call returns `0x31`. None of this is visible outside a VM.

`kgspExecuteBooterUnloadIfNeeded` cannot recover it either: it returns early when WPR2
is down, and WPR2 is down precisely because the load failed.

The current candidate fix (`passthrough-acr-sequence.patch`) runs the unload ucode
directly to clear the stamp and then retries the load, gated on the `0x29` code so the
`0x31` hijack path is untouched. **It is committed but not yet verified end to end** —
the guest used for testing degraded before a clean run completed.

## Where that leaves passthrough

- Passing a **locked** CMP 170HX through works normally. Install the stock driver in
  the guest and it behaves like any other GA100 at 8 GB.
- There is currently **no way to get the unlocked configuration into a guest**. The
  host route is erased by QEMU's reset; the guest route is refused by the SEC2 booter.
- The remaining work is on the guest side and is now a named problem rather than a
  mystery: clear the ACR version stamp between Booter Load attempts. Whether that
  alone is sufficient, or whether `0x15` (`ACR_ERROR_FLCN_REG_ACCESS`) is a second
  independent failure, is still open.

## Reproducing

The register probe used throughout reads BAR0 read-only via
`/sys/bus/pci/devices/<bdf>/resource0` and needs no driver, so it works on the host,
on a vfio-bound card, and inside the guest:

```
FBPA_CFG1              0x009A0204
FBPA_CSTATUS           0x009A020C   RAMAMOUNT 16:0 = MB per FBPA
MMU_LOCAL_MEMORY_RANGE 0x00100CE0
OPT_FBPA_DISABLE       0x00820368
FBPA_PLM               0x009A0148
WPR_PLM                0x001FA7C4
FEAT_PLM               0x00823804

total FB = CSTATUS.RAMAMOUNT * (24 - popcount(OPT_FBPA_DISABLE))
```

Booter mailbox codes are already logged by the existing SEC2 debug output:

```
dmesg | grep -oE "Booter failed with non-zero error code: 0x[0-9a-f]+" | sort | uniq -c
```
