# P2P 合并说明

以 `cmpunlocker-0.4` 为基础，已融合附件中 `cmpunlocker-p2p` 的 `--p2p`
参数及其驱动实现。本仓库根目录即合并后的主项目。

## 使用

在项目根目录运行：

```bash
sudo ./install.sh --p2p
```

可以与原有 `--profile=8gb|10gb`、`--no-iommu`、`--no-gen2-service`、
`--no-passthrough` 一起使用。不传 `--p2p` 时，全部可选 P2P 驱动补丁关闭。
安装完成后需彻底关机再开机。

直接构建也支持：

```bash
sudo env CMPUNLOCKER_ENABLE_P2P=1 ./driver/build.sh
```

重新运行不带 `--p2p` 的安装命令可关闭 P2P，随后冷启动。升级内核后，
仍按 `0.4` 的方式手动重新安装；需要 P2P 时务必继续传入该参数。

## 实现范围

| 内容 | 合并方式 |
| --- | --- |
| GSP 的 P2P 读写能力覆盖 | 将 `cmpUnlockForceP2PCaps()` 的逻辑转成 `0.4` 原生补丁，保留两个 CMP 设备 ID 的判断。 |
| BAR1 P2P 完整路径 | 迁入 HAL 选择、映射创建/删除、BAR1 总线地址传递、PTE/物理地址改写、UVM 和 IOVAS 相关改动。 |
| mailbox 预注册修正 | BAR1 模式下跳过 mailbox peer 预注册，避免已有 peer mask 阻断 BAR1。 |
| 主机读能力修正 | 迁入 CMP 读能力覆盖，并去掉原补丁对已禁用 `0014` 调试补丁的上下文依赖。 |
| BAR1 resize | 保留 `0.4` 已有的等效实现，不重复应用同一功能的补丁。 |
| 安装配置 | 将 Gen2 与 `RMForceStaticBar1=1;RMPcieP2PType=1` 写入同一条 `NVreg_RegistryDwords`，在生成 initramfs 前完成。 |
| 关闭与重建 | P2P 开关进入缓存标记；切换开关会重新解压驱动源码。关闭时同时清除配置中的 P2P 参数。 |
| 验证 | 记录 `p2p_enabled`，增加能力矩阵提示、真实 CUDA 读写校验程序和离线回归测试。 |

四个 P2P 驱动补丁统一位于 `driver/patches/p2p/`。没有整体替换 `0.4`
的解锁实现，也没有迁入与 P2P 无关的超频、时序调整和软件包持久化系统。
原有 8GB/10GB/混合显存识别、Gen2、直通实现继续保留。

## 目标主机验证

每张参与 P2P 的 GPU 都需要足够大的 BAR1，且主机 PCIe 路径必须支持真实
peer 读写。源项目使用每卡 64 GiB BAR1。BAR1 扩容由驱动在加载时通过 REBAR
完成，前提是 BIOS 开启 Above-4G Decoding 并提供足够大的 MMIO High 地址
空间；BIOS 不分配时驱动无法凭空获得地址空间，BAR1 保持出厂尺寸，P2P 不可用。

```bash
sudo ./verify.sh
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
nvcc -O2 -arch=sm_80 -o /tmp/cmpunlocker-test-p2p tools/test-p2p.cu
timeout 120s /tmp/cmpunlocker-test-p2p 0 1
```

能力覆盖会让查询结果显示支持，不能据此认定传输成功。CUDA 程序用不同
数据初始化两张卡，分别执行 peer 读和写，并校验目标及源数据，以检测
错误的本地显存别名映射。不指定设备编号时测试所有可见 CUDA GPU 的有向配对。

## 本次验证与限制

- Shell、Python 和四个 P2P 补丁的语法检查通过。
- 10 项离线回归测试全部通过，覆盖参数传递、默认关闭、混合显存配置、开关和补丁变化引起的缓存失效、
  补丁失败中止、initramfs 配置顺序及失败上报。
- 使用重建的补丁上下文验证了 P2P 补丁组合可以在不引入已禁用调试补丁的情况下应用。
- 将迁入的能力覆盖 C 代码块独立编译执行，验证两个 CMP ID 生效、其他 ID 的状态保持不变。

运行离线测试：

```bash
python3 -m unittest discover -s tests -v
```


完整英文实现说明见 [P2P.md](P2P.md)。
