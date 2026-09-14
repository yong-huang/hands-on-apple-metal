# 13 · Core Image 滤镜链与 Metal 互操作
> 用 CIFilter 链（CIHueAdjust → CIExposureAdjust）处理图像，回读像素验证滤镜确实生效，并演示 Core Image 与 Metal 共享 GPU 纹理的互操作路径。
## 1. 核心概念
`CIContext(mtlDevice:)` 让 Core Image 跑在 Metal 设备上；`CIImage(texture:)` / `ciContext.render(_:to:)` 打通 CIFilter 链与 MTLTexture。
## 2. 快速开始
```bash
./ci_metal.sh
```
## 3. 文件结构
```
13_ci_metal/
├── README.md
├── ci_metal.sh
├── ci_metal.swift
└── images/ (三件套)
```
## 4. 深入要点
- CIContext 绑定 MTLDevice 后，滤镜链全程留在 GPU，无需 CPU 中转
- 本实验回读像素做差验证 91% 像素被修改——滤镜链真实生效
- 互操作两条路：CIImage(texture:) 包 MTLTexture 进滤镜链；ciContext.render 输出到 MTLTexture 给后续 Metal pass 用
→ 返回清单：[metal_system.md](../../docs/metal_system.md)
