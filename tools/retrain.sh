#!/bin/bash
set -euo pipefail

echo "retrain: 已停用。PCIe Gen2 协商现在由 nvidia 驱动在每张 CMP 卡初始化期间完成。"
echo "retrain: 请勿在驱动已运行时直接重训链路；这会与 GPU/GSP 的 BAR 访问竞争，并可能使显卡不可用。"
exit 0
