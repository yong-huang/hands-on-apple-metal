# 14 · Accelerate/vDSP vs Metal 同任务对照
> 同一个"向量缩放"任务分别用 vDSP（`vDSP_vsmul`）和 Metal compute kernel 实现，各跑 100 次计量，算出等效内存带宽。
## 1. 核心概念
vDSP 走 CPU 向量单元免提交零开销；Metal 每次 commit + waitUntilCompleted 有约 0.25ms 同步开销。
## 2. 快速开始
```bash
./vdsp_metal.sh
```
## 3. 文件结构
```
14_vdsp_metal/
├── README.md
├── vdsp_metal.sh
├── vdsp_metal.swift
└── images/ (三件套)
```
## 4. 深入要点
- 1M float 下 vDSP 达 ~350 GB/s，Metal 只有 ~33 GB/s——不是 GPU 慢，是每次提交的同步开销（~0.25ms）主导了小任务耗时
- 计带宽务必按单次迭代时间算（总耗时 ÷ 迭代次数），否则结果差 100 倍
- 结论：小数据/单次同步任务用 vDSP；数据量大（几十 MB+）或可批量提交时 Metal 带宽优势才显现
→ 返回清单：[metal_system.md](../../docs/metal_system.md)
