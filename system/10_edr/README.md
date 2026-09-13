# 10 · EDR 扩展动态范围渲染
> Metal 渲染超出 SDR 白的亮度值，在 HDR 屏上呈现真实更亮的绿光斑。
## 1. 核心概念
`rgba16Float` 精度 + `extendedLinearSRGB` 色彩空间 + EDR headroom = 亮度可超 SDR 白。
## 2. 快速开始
```bash
./edr.sh
```
## 3. 文件结构
```
10_edr/
├── README.md
├── edr.sh
├── edr.swift
└── images/ (三件套)
```
## 4. 深入要点
- Metal 裁剪空间 z ∈ [0,1]，与 OpenGL 不同
- EDR headroom = maximumPotentialExtendedDynamicRangeColorComponentValue
→ 返回清单：[metal_system.md](../../metal_system.md)
