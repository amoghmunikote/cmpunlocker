# cmpunlocker

用于解锁 NVIDIA CMP 170HX（GA100）矿卡的工具。它可恢复因固件/OTP 配置而受限的完整 SM 计算性能和 HBM2e 显存容量。

适用于 Linux 上的 **nvidia-open 驱动 610.43.0x**。cmpunlocker **不会**安装完整的 NVIDIA 用户空间软件包；它只会修补并安装开源内核模块。

一次安装支持**一张或多张** CMP 170HX GPU，包括 **8GB + 10GB 混插**的系统。每张 GPU 的解锁显存规格会在 GSP 启动时根据其 PCI 设备 ID 选择。

欢迎加入我们的 **[Discord 社区](https://discord.gg/CdHSakKSFv)** 获取支持和参与讨论。

---

## 原理

CMP 170HX 使用物理上完整的 GA100 芯片（与 A100 使用相同硅片），但其计算和显存功能受到人为限制。本工具通过驱动内解锁路径（开放 SEC2 Booter PLM、由主机写入 SS0/SS1/CFG1/LMR，以及调整 FB/PMA），在修补后的模块为每张匹配 GPU（`0x20C2` / `0x2082`）启动 GSP 时自动执行解锁。

显存规格由卡的型号决定：

| 实体显存 | PCI ID | 解锁后的显存 | CFG1 | LMR |
|---|---|---|---|---|
| **8 GB** | `0x20C2` | **64 GB** | `0x02779000` | `0x0000020B` |
| **10 GB** | `0x2082` | **40 GB** | `0x02669000` | `0x0000028A` |

---

## 效果展示

以下为应用解锁后的显存与性能结果：

### 显存解锁结果

<img alt="显存解锁结果" src="https://github.com/user-attachments/assets/ae062bd8-e3a7-4e73-b9a4-fbcde53f3c7b" width="100%" style="max-width: 900px;" />

### 性能测试（[OpenCL-Benchmark](https://github.com/ProjectPhysX/OpenCL-Benchmark)）

<img alt="性能测试结果" src="https://github.com/user-attachments/assets/2501506d-420f-4014-9574-b1bd0290eb60" width="100%" style="max-width: 900px;" />

---

## 前置条件

- Linux（x86-64）
- Root 权限
- 一张或多张 NVIDIA CMP 170HX GPU（`10de:20c2` 和/或 `10de:2082`）
- 已安装 **nvidia-open 610.43.0x**（库文件和固件）
- 与当前内核匹配的内核头文件（`linux-headers-$(uname -r)` / `kernel-devel`）
- 已关闭 Secure Boot（修补后的模块未签名）
- 首次安装时可访问网络（用于下载匹配版本的 `open-gpu-kernel-modules` 源码）
- Python 3（构建时使用）

---

## 安装

只需一条命令。工具会枚举全部 CMP 170HX GPU，按 PCI ID 判定每张卡是 8GB 还是 10GB，然后构建修补后的开源内核模块至 `/lib/modules/$(uname -r)/updates/cmpunlocker/`。

```bash
sudo ./install.sh
```

可选：覆盖安装元数据（运行时的解锁规格仍始终以每张 GPU 的 PCI ID 为准）：

```bash
sudo ./install.sh --profile=8gb
sudo ./install.sh --profile=10gb
```

如果模块无法正常热重载，或任意 GPU 仍显示原始显存容量，请执行一次**冷重启**（完全关机后再开机）。

安装元数据位于 `/lib/modules/$(uname -r)/updates/cmpunlocker/`：

| 文件 | 内容 |
|---|---|
| `card_profile` | `8gb`、`10gb` 或 `mixed` |
| `unlock_geometry` | `64GB`、`40GB` 或 `mixed` |
| `gpu_inventory` | 每张 GPU 一行：`BDF devid profile expected_mib` |

---

## 验证

重启后，请验证**每张**可解锁 GPU：

```bash
sudo ./verify.sh
```

`verify.sh` 会按 PCI 总线 ID 检查每张卡的 `nvidia-smi` 显存容量是否符合预期（8GB 卡约为 65536 MiB，10GB 卡约为 40960 MiB），并在可用时显示 `SEC2_DEBUG` 内核日志。

也可以手动检查：

```bash
nvidia-smi
# 每张 8GB 卡：应显示约 65536 MiB
# 每张 10GB 卡：应显示约 40960 MiB

nvidia-smi --query-gpu=pci.bus_id,memory.total,pcie.link.gen.current,pcie.link.gen.max,clocks.max.sm --format=csv
# 重启后应显示 pcie.link.gen.current=2 且 pcie.link.gen.max=2

sudo lspci -d 10de:20c2 -vv | grep -E 'LnkCap:|LnkSta:'
# 应显示 LnkSta: Speed 5GT/s（而非 2.5GT/s）

sudo dmesg | grep SEC2_DEBUG
# 预期日志：PLM 打开为 0xffffffff，并出现 CFG1/LMR/SS0/SS1 写入及 late PMA

cat /lib/modules/$(uname -r)/updates/cmpunlocker/gpu_inventory
cat /lib/modules/$(uname -r)/updates/cmpunlocker/card_profile
```

## 解锁内容

| 功能 | 状态 |
|---|---|
| 完整 SM 计算吞吐量（SS0/SS1） | 已支持 ✓ |
| 显存规格（8GB 卡至 64GB，10GB 卡至 40GB） | 已支持 ✓ |
| PCIe Gen2 链路（`5GT/s`，设备最高速率 ≥ 2） | 已支持 ✓ |
| 多 GPU / 8GB 与 10GB 混插安装 | 已支持 ✓ |
| 重启后保持生效（修补后的模块） | 已支持 ✓ |

---

## 卸载

恢复加载原始模块：

```bash
sudo ./remove.sh --yes
```

该命令会删除 `/lib/modules/*/updates/cmpunlocker/`、运行 `depmod`，并尝试重新加载原始 NVIDIA 模块。如果 GPU 未能正常恢复，请重启系统。

---

## 支持与社区

遇到问题或需要帮助？欢迎加入 [Discord 社区](https://discord.gg/CdHSakKSFv) 交流讨论。
