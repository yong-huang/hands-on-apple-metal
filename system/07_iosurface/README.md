# 07 · IOSurface 跨框架零拷贝

> 同一块 IOSurface 先包成 MTLTexture 由 GPU compute 写入渐变，CPU 直接从基址读回验证一致（零拷贝），再包成 CIImage 走 Core Image 管线——这正是 CVMetalTextureCache、Core Image 互操作的底层机制。读完你将理解跨框架共享像素的前提条件，以及垂直翻转、色彩空间两个必踩坑。

## Background

Metal、Core Image、Core Video 各有自己的图像容器：MTLTexture、CIImage、CVPixelBuffer。跨框架传递像素的朴素做法是 memcpy——从一种容器读出，写进另一种。

痛点随管线变长而放大。一张 256×256 的 BGRA 图一帧 256KB，视频管线每秒几十帧，全量拷贝白烧内存带宽；拷贝路径一多，色彩空间、行对齐、线程归属处处可能出错。

IOSurface 是 Apple 给出的公共底层对象：Metal / Core Image / CoreVideo / VideoToolbox 都能包装同一块 IOSurface，数据只存一份。

它就是 CVMetalTextureCache 这类"零拷贝桥"的地基——本实验绕开封装，直接用它走一遍 GPU 写、CPU 读、Core Image 再读的完整闭环。

## What

IOSurface 是一块可被多个图像框架同时包装的共享内存表面。所谓零拷贝，指各框架拿到的是同一块内存的不同视图，而不是数据的副本。

一句话心智模型：**可以把 IOSurface 想成一块公共白板**——GPU 往上写，CPU 直接读，Core Image 包一层接着用；传递的是白板本身，不是白板的照片。

类比有个前提：白板必须先注册"共享资格"。

用 `CVPixelBufferCreate` 建缓冲时要带上两个 key——`kCVPixelBufferIOSurfacePropertiesKey`（IOSurface 支撑）和 `kCVPixelBufferMetalCompatibilityKey`（Metal 兼容）——缺了就绑不上 Metal。

本实验的闭环分三段：GPU compute（compute shader：不画三角形、直接并行读写内存的 GPU 程序）写入渐变 → CPU 从基址读回逐点比对 → 同一块 IOSurface 再包成 CIImage 走 Core Image 渲染。

## When to Use

在自己建像素缓冲要给 Metal 用时需要它：合成测试帧、CPU 生成的图像送 GPU 处理，都靠这两个 key 打通。

在搭建跨框架管线时用它：Metal 写入、Core Image 滤镜、VideoToolbox 编解码，全链路共享同一块内存。

在排查零拷贝问题时用它：CVMetalTextureCache 报 -6660 的根源就在 IOSurface 资格声明（见 How It Works）。

何时不用：单框架内部的数据流转不必手动碰 IOSurface，框架自己管理；CPU 与 GPU 各持一份独立数据、无需共享时，普通 buffer 更简单。

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| 手动 IOSurface 包装（本实验） | 显式创建、显式包装，控制粒度最细 | 自建管线、排查底层机制 |
| CVMetalTextureCache | 封装好的相机帧零拷贝桥，底层正是 IOSurface | 相机/视频采集场景 |
| memcpy 拷贝 | 简单直白，带宽全花在搬运上 | 一次性、低频、小图 |

## Quick Start

前置条件：macOS 与 Swift 命令行编译环境。脚本一条龙执行 build → observe → clean：

```bash
./iosurface.sh
```

预期输出（按 iosurface.sh 与 iosurface.swift 推断；Device 一行因机器而异）：

```
=====> [build] swiftc
OK

=====> [observe] IOSurface 零拷贝：GPU 写 → CPU 读 → Core Image 再读
=== IOSurface 跨框架零拷贝 ===
Device: Apple M5 Pro
MTLTexture 包装自 IOSurface：256x256
✅ CPU 读回与 GPU 写入一致（零拷贝共享成立）
Core Image 回读蓝色通道=128 的比例: 100.0%
✅ 同一块 IOSurface 无缝进入 Core Image 管线

提示: CVMetalTextureCache 底层正是 IOSurface——这就是相机帧免 memcpy 进 Metal 的原因。

实验结束。
```

验证方法来自源码的两处断言：CPU 侧以 16 像素步进采样、逐点比对（容差 ±2），不一致数为 0 才打印 ✅；Core Image 侧统计蓝色通道等于 128 的像素比例，超过 90% 才判通过。

建缓冲与包装的核心代码（随后说明这段在做什么）：

```swift
let status = CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA,
                                 [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                  kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                                 &pb)
```

- 这段在创建带 IOSurface 支撑与 Metal 兼容声明的像素缓冲——两个 key 就是白板的"共享资格"。

```swift
let tex = dev.makeTexture(descriptor: desc, iosurface: surface, plane: 0)!
```

- 这段在把 IOSurface 包装成 MTLTexture（256×256、`.bgra8Unorm`、`usage` 含 `.shaderWrite`/`.shaderRead`）——GPU 读写的就是这块共享内存。

## How It Works

这节按四步走完 GPU 写、CPU 读、Core Image 再读的闭环。你在预期输出里看到的两个 ✅，分别对应第三步和第四步的验证。

第一步，创建 IOSurface 支撑的 CVPixelBuffer（Quick Start 第一段代码）。

第二步，包装成 MTLTexture：`makeTexture(descriptor:iosurface:plane:)` 不分配新内存，只是给同一块表面发了一张 Metal 的"引用凭证"，`storageMode = .shared` 保证 CPU 与 GPU 看到同一份字节。

第三步，GPU compute 写入渐变：kernel（compute 程序中每个线程执行一次的函数）对每个像素写 `float4(uv.x, uv.y, 0.5, 1.0)`（uv 为归一化到 0~1 的像素坐标）——红随 x 增、绿随 y 增、蓝恒为 0.5。

`cb.waitUntilCompleted()` 等写入落地。

第四步是验证的两只手。CPU 侧：`CVPixelBufferLockBaseAddress` 拿到基址，按 BGRA 内存布局逐点读（`p[0]=B`，0.5 编码为 128；`p[1]=G`；`p[2]=R`），与期望值比对——完全一致，证明 GPU 写的 CPU 直接管看到，全程无 memcpy。

Core Image 侧：`CIImage(mtlTexture:)` 包装同一纹理后渲染回位图，统计蓝色通道等于 128 的比例——100% 通过，证明同一块表面无缝进入 Core Image 管线。

这条机制向上支撑了整个生态：CVMetalTextureCache 底层正是 IOSurface，相机帧免 memcpy 进 Metal（见 03_camera_texture）靠的就是它；缺 IOSurface 支撑时报 -6660，根源也在这里。

## Pitfalls & Q&A

**`CIImage(mtlTexture:)` 之后画面上下颠倒。** 现象：同一纹理经 Core Image 渲染，内容垂直翻转。原因：Core Image 的坐标约定与 Metal 纹理原点不同，属于框架约定差异。解法：渲染时接受翻转或预先补偿——本实验只验证蓝色通道，翻转不影响结论。

**回读数值 0.5 变成 188 而不是 128。** 现象：浮点 0.5 经 Core Image 渲到位图后偏大。原因：默认 sRGB 色彩空间对中间调做非线性编码。解法：回读时指定 `linearSRGB` 色彩空间，数值按线性 RGB 直存。

**像素缓冲绑不上 Metal（-6660）。** 现象：建纹理或建缓存失败。原因：缓冲缺 IOSurface 支撑或 Metal 兼容声明。

解法：`CVPixelBufferCreate` 同时带上 `kCVPixelBufferIOSurfacePropertiesKey` 与 `kCVPixelBufferMetalCompatibilityKey`。

**Q：三个框架各包装一次，数据真的只有一份吗？** 是——GPU 写入后 CPU 从基址读回完全一致，同一块 IOSurface 再进 Core Image 回读蓝色通道 100% 命中。这就是 Quick Start 两个 ✅ 各自证明的事。
