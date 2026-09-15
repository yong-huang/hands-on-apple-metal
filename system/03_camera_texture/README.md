# 03 · 相机实时滤镜：CVMetalTextureCache 零拷贝管线

> 相机每秒吐 30 帧 720p BGRA——每帧 3.6MB，从 CPU 拷到 GPU 再处理就是浪费。
> CVMetalTextureCache 让像素缓冲与 Metal 纹理共享同一块内存（零拷贝），
> fragment 滤镜直接在上屏前完成。相机不可用时的合成帧回退也一并实现。

## 1. 为什么需要它

视频会议美颜、AR 贴纸、直播特效——所有实时相机应用的第一站都是这条管线：采集 → 零拷贝上 GPU → 滤镜 → 呈现。把 CVMetalTextureCache 的三个隐性约束（IOSurface、锁序、线程）踩明白，视频类 Metal 开发就没暗礁了。

## 2. 总览：核心机制一图看懂

![相机滤镜数据流](images/camera_texture.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/system/03_camera_texture/images/camera_texture.html)（或本地打开 [`images/camera_texture.html`](images/camera_texture.html)）。

相机帧与合成回退帧都汇入 CVMetalTextureCache 零拷贝桥，fragment 四滤镜后呈现。一句话心智模型：**像素缓冲即 Metal 纹理，桥只递地址不搬数据**。

## 3. 快速开始

```bash
./camera_texture.sh           # 一条龙：build → observe（12 秒）→ clean
# 窗口从第一帧起就显示合成测试图案（不会再白屏）；
# 首次运行弹相机授权，点「允许」后自动切换到真摄像头画面
```

真实输出（未授权环境，合成回退路径）：

```
相机权限状态码: 0（未决定）
⚠️ 相机不可用（未授权或被拒）。回退到合成测试帧验证 Metal 管线；
合成帧回退：Timer 已触发，开始产出测试帧
处理帧率: 31 fps（当前滤镜：原图（镜像））
```

窗口中实时画面 + 底部提示；按 1-4 切换原图/黑白/反色/漫画。验证方法：处理帧率稳定 29-31 fps；切滤镜时日志同步打印。

## 4. 核心概念

### 4.1 CVMetalTextureCache 的三个隐性约束（全部实测踩过）

1. **合成缓冲必须 IOSurface 支持**：`CVPixelBufferCreate` 不显式传 `kCVPixelBufferIOSurfacePropertiesKey`，`CreateTextureFromImage` 返回 -6660 且无解释——相机帧天然 IOSurface 无此问题，合成帧必踩。
2. **CPU 锁着时不能建纹理**：`CVPixelBufferLockBaseAddress` 持有期间创建纹理同样 -6660——先填完、解锁、再渲染。
3. **线程归属**：纹理创建与呈现都在主线程做，相机回调投递 `DispatchQueue.main.async`。

### 4.2 权限生命周期：先有画面，再换真相机

启动顺序：**合成帧先行**（窗口从第一帧起就有内容），随后按权限结果决定是否切换——authorized 停合成帧启动相机；notDetermined 弹窗，允许即切、拒绝则留在合成帧。这修复了「等授权期间窗口全白」的体验问题：**CAMetalLayer 无 drawable 呈现时就是白的**，任何等待期都必须有帧在渲染。

### 4.3 帧回调与渲染的线程模型

相机回调在后台队列（`setSampleBufferDelegate` 专用队列），渲染投递回主线程。`alwaysDiscardsLateVideoFrames = true` 保证丢帧不积压——实时管线宁可丢帧不可延迟。

### 4.4 四滤镜的 fragment 实现

原图（镜像 uv.x）、黑白（亮度加权）、反色（1−c）、漫画（4 级量化 + 相邻采样差分边缘）。全部在一个 fragment 函数里以 `switch (u.filter)` 分发——一次 draw 完成所有风格。

## 5. 关键代码

```swift
// 零拷贝桥：像素缓冲 → Metal 纹理
CVMetalTextureCacheCreateTextureFromImage(
    kCFAllocatorDefault, textureCache, pixelBuffer, nil,
    .bgra8Unorm, w, h, 0, &tex)
let texture = CVMetalTextureGetTexture(tex!)
enc.setFragmentTexture(texture, index: 0)
```

合成帧的 IOSurface 声明：

```swift
let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
CVPixelBufferCreate(kCFAllocatorDefault, w, h, .bgra8Unorm, attrs as CFDictionary, &pb)
```

## 6. 文件结构

```
03_camera_texture/
├── README.md                         # 本文档
├── camera_texture.sh                 # 主演示脚本（打包最小 .app 携带权限声明）
├── camera_texture.swift              # 实验程序：会话/缓存/滤镜/回退
└── images/
    ├── camera_texture.dataflow.json  # 图源
    ├── camera_texture.html           # 交互版
    └── camera_texture.svg            # 双主题矢量版
```

## 7. 深入要点

- **为什么相机帧天然能进缓存而合成帧不行？** AVFoundation 产出的像素缓冲必为 IOSurface-backed；`CVPixelBufferCreate` 默认不保证——显式传属性即可。
- **最小 .app 打包的用途？** TCC 权限归属需要 Info.plist（NSCameraUsageDescription）；裸二进制的权限会被归属到父进程（终端）且不可持久。
- **30fps 的渲染为什么放主线程也行？** 相机 30fps ≪ 屏幕刷新，主线程渲染回调开销小；高帧率场景应换独立渲染队列 + 无锁交换。

## 8. 总结

视频管线的地基打完：采集、零拷贝、滤镜、降级策略一应俱全。下一篇在此之上叠加 AI——CoreML/Neural Engine 推理结果变成 Metal 的输入。

→ 下一篇：[04 · 三路推理基准]（清单 docs/metal_system.md 项目 4，待实现）
MDEOF
echo "README 03 done"