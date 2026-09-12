<div align="center" style="text-align: center;">

<h1>cmpunlocker</h1>

<p>
  <b>Unlock tool for the NVIDIA CMP 170HX (GA100) mining card.</b>
  <br>
  Restores full SM compute throughput and unlocked HBM2e memory geometry that are restricted in firmware/OTP configuration.
</p>

<h3>
  <a href="https://discord.gg/CdHSakKSFv">Discord</a>
</h3>

</div>

**[Join our Discord community](https://discord.gg/CdHSakKSFv)** for support and discussions.

---

## Proof of Concept

Below are memory and performance results after applying the unlock:

<table>
  <tr>
    <td><b>Memory Unlock Results</b></td>
  </tr>
  <tr>
    <td><img alt="memory unlock" src="https://github.com/user-attachments/assets/ae062bd8-e3a7-4e73-b9a4-fbcde53f3c7b" width="100%" style="max-width: 900px;" /></td>
  </tr>
</table>

<table>
  <tr>
    <td><b>Performance Benchmarks (<a href="https://github.com/ProjectPhysX/OpenCL-Benchmark">OpenCL-Benchmark</a>)</b></td>
  </tr>
  <tr>
    <td><img alt="performance benchmarks" src="https://github.com/user-attachments/assets/2501506d-420f-4014-9574-b1bd0290eb60" width="100%" style="max-width: 900px;" /></td>
  </tr>
</table>

---

## Requirements

- Linux (x86-64)
- Root access
- NVIDIA CMP 170HX
- **nvidia-open 610.43.0x already installed** (libs + firmware)
- Kernel headers matching the running kernel (`linux-headers-$(uname -r)` / `kernel-devel`)
- Secure Boot disabled (patched modules are unsigned)
- Network access on first install (downloads matching stock `open-gpu-kernel-modules` sources)
- Python 3 (used at build time to select 8GB/10GB geometry)

---

## Install

To install cmpunlocker, run the following command:

```bash
sudo ./install.sh
```

To force a certain memory profile, use the `--profile` option:

```bash
sudo ./install.sh --profile=8gb    # 8GB card → 64GB unlock
sudo ./install.sh --profile=10gb   # 10GB card → 40GB unlock
```

Then perform a cold reboot (full power off, then boot).

## What Gets Unlocked

<table>
  <tr>
    <th>Feature</th>
    <th>Status</th>
  </tr>
  <tr>
    <td>Full SM compute throughput (SS0/SS1)</td>
    <td>Working ✓</td>
  </tr>
  <tr>
    <td>Memory geometry (64GB on 8GB cards, 40GB on 10GB cards)</td>
    <td>Working ✓</td>
  </tr>
  <tr>
    <td>PCIe Gen 2 speeds</td>
    <td>Working ✓</td>
  </tr>
  <tr>
    <td>Full BAR1 Size (64GB)</td>
    <td>Working ✓</td>
  </tr>
  <tr>
    <td>JTAG (Host2Jtag register access)</td>
    <td>Working ✓</td>
  </tr>
  <tr>
    <td>VFIO-based passthrough</td>
    <td>Working ✓</td>
  </tr>
  <tr>
    <td>GPU profiling</td>
    <td>Working ✓</td>
  </tr>
  <tr>
    <td>Persistence across reboot (patched modules)</td>
    <td>Working ✓</td>
  </tr>
</table>

---

## Uninstall

To uninstall cmpunlocker, run the following command:

```bash
sudo ./uninstall.sh --yes
```

Then perform a cold reboot (full power off, then boot).

## Contributions

Please read [docs/CONTRIBUTING.md](https://github.com/amoghmunikote/cmpunlocker/blob/master/docs/CONTRIBUTING.md) before opening a PR.

## Support & Community

Having issues? Need help? Join our [Discord community](https://discord.gg/CdHSakKSFv) to discuss with other users and get support.
