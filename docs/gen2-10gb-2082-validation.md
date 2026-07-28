# PCIe Gen2 validation on the 10 GB CMP 170HX (`10de:2082`)

This documents one successful 10 GB validation of the transient-window Gen2
retrain. It is a single-system result, not a claim that every `2082` board or
host platform will behave identically.

The early-retrain mechanism is based on
[`studebaker8/cmp170hx-gen2`](https://github.com/studebaker8/cmp170hx-gen2):
patch `0007` transiently exposes Gen2 capability during GSP bootstrap, and a
userspace service repeatedly initiates retraining from the upstream bridge
while that window is open.

## Test configuration

| Component | Configuration |
|---|---|
| GPU | CMP 170HX 10 GB, `10de:2082`, revision A1 |
| GPU BDF | `0000:02:00.0` |
| VBIOS | `92.00.66.00.02` |
| Driver | NVIDIA open kernel module `610.43.02` |
| Unlocked memory | `40960 MiB` |
| Maximum SM clock | `1410 MHz` |
| OS | Ubuntu 26.04 LTS |
| Kernel | `7.0.0-28-generic` |
| CPU | Intel Xeon E5-2690 v4 |
| Mainboard | Supermicro X10DRG-Q, BIOS 3.2 |
| Upstream port | `0000:00:03.0`, Intel `8086:6f08` |
| Upstream capability | 8.0 GT/s, x16 maximum |
| Physical GPU link width | x4 |

The successful boot had `intel_iommu=on iommu=pt` enabled, but the retrain
helper does not use the IOMMU and this result should not be interpreted as
evidence that IOMMU is required.

## Boot timing and result

On the validated cold boot:

| Event | Monotonic boot time |
|---|---:|
| `sysinit.target` reached | 3.961 s |
| Early retrain helper started | 7.662 s |
| Driver logged transient `CAP2=0x06` | 7.804 s |
| Gen2 trained on iteration 4 | 7.918 s |

The successful service record was:

```text
0000:02:00.0: SUCCESS Gen2 at iteration 4;
LnkSta=0x1042; LnkCap2=0x00000006
```

Negotiated-link and functional results:

| Measurement | Before | After |
|---|---:|---:|
| `LnkSta` | `0x1041` | `0x1042` |
| sysfs `current_link_speed` | 2.5 GT/s | 5.0 GT/s |
| Link width | x4 | x4 |
| Pinned H2D bandwidth | approximately 0.82 GB/s | 1.633 GB/s |
| Pinned D2H bandwidth | approximately 0.84 GB/s | 1.679 GB/s |
| Unlocked memory | 40960 MiB | 40960 MiB |
| Maximum SM clock | 1410 MHz | 1410 MHz |

The post-change bandwidth test used a 512 MiB pinned PyTorch tensor, two warmup
copies, and eight measured copies in each direction. No PCIe AER errors,
NVIDIA Xids, or fallen-off-bus messages were observed.

## Differences from the published 8 GB result

The original public validation used the 8 GB `10de:20c2` variant, unlocked to
64 GB, on an AMD B650M host. This validation used the 10 GB `10de:2082`
variant, unlocked to 40 GB, on an Intel Xeon platform.

There are two important reporting differences on this 10 GB configuration:

1. After the transient capability window closed, sysfs reported
   `max_link_speed=2.5 GT/s` while the negotiated
   `current_link_speed=5.0 GT/s`. The negotiated speed and transfer bandwidth,
   not the post-window maximum capability, are authoritative.
2. NVIDIA NVML reported `pcie.link.gen.current=1` and
   `pcie.link.gen.max=1` even though PCI configuration `LnkSta=0x1042`, sysfs
   reported 5.0 GT/s, and host transfer bandwidth doubled. Do not use NVML as
   the only success criterion on this configuration.

The existing `0008-pcie-gen2-probe-retrain.patch` also printed:

```text
CMP Gen2: PCIe retrain completed without Gen2 link
(status=0x1042, ret=0)
```

`0x1042` already encodes Gen2 in the low four bits. The false failure occurred
because the check additionally required `PCI_EXP_LNKSTA_DLLLA`, an optional
status bit that was not set on this endpoint. The accompanying patch removes
that extra requirement.

## Operation and rollback

The installer enables `cmp-gen2-early.service` but does not start it in the
running desktop session. The service dynamically discovers each supported CMP
GPU and its immediate upstream PCI bridge, validates vendor/device/class
identifiers, and stops after Gen2 is negotiated or after a bounded 30-second
attempt window.

Verify:

```bash
sudo ./tools/cmp-gen2-service.sh verify
```

Remove only the early retrain service while keeping the patched driver and
memory unlock:

```bash
sudo ./tools/cmp-gen2-service.sh remove
```

For first-boot recovery, add this temporary kernel parameter:

```text
systemd.mask=cmp-gen2-early.service
```
