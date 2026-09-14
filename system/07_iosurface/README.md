# 07 · IOSurface 跨框架零拷贝
> 同一块 IOSurface 先包成 MTLTexture 由 GPU compute 写入渐变，CPU 直接从基址读回验证一致（零拷贝），再包成 CIImage 走 Core Image 管线——CVMetalTextureCache、Core Image 互操作的底层机制。
## 1. 核心概念
IOSurface 是 Apple 各图像框架（Metal / Core Image / CoreVideo / VideoToolbox）共享像素的公共货币；`CVPixelBufferCreate` 带 `kCVPixelBufferIOSurfacePropertiesKey` + `kCVPixelBufferMetalCompatibilityKey` 才能被 Metal 绑定。
## 2. 快速开始
```bash
./iosurface.sh
```
## 3. 文件结构
```
07_iosurface/
├── README.md
├── iosurface.sh
├── iosurface.swift
└── images/ (三件套)
```
## 4. 深入要点
- GPU 写入后 CPU 从 IOSurface 基址采样读回完全一致——全程无 memcpy
- 同一块 IOSurface 再包 CIImage 100% 通过，验证跨框架共享
- 两个坑：CIImage(mtlTexture:) 会垂直翻转（Core Image 约定）；回读色彩空间要按 linearSRGB，否则 0.5 会被 sRGB 编码成 188
- CVMetalTextureCache 缺 IOSurface 支撑时报 -6660，根源就在这里
→ 返回清单：[metal_system.md](../../docs/metal_system.md)
