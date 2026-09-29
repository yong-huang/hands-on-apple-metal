# 03 · 相机实时滤镜：CVMetalTextureCache 零拷贝管线

> 相机每秒吐 30 帧 720p BGRA——每帧 3.6MB，从 CPU 拷到 GPU 再处理就是浪费。CVMetalTextureCache 让像素缓冲与 Metal 纹理共享同一块内存（零拷贝），fragment 滤镜直接在上屏前完成，相机不可用时的合成帧回退也一并实现。读完你将掌握实时视频管线的搭建、零拷贝的三个隐性约束与降级策略。

## Background

拿到相机帧之后想上 GPU 处理，此前的常规做法是：把 CVPixelBuffer（Core Video 框架的像素缓冲，CPU 侧的图像容器）的内容用 CPU 读出，写进一张 Metal 纹理，或者先转成 UIImage 再走图片渲染路径。

痛点在实时场景里被放大。30fps 的 720p BGRA（每像素按蓝、绿、红、透明度各 1 字节编码的像素格式，故 1280×720 一帧约 3.6MB）每帧 3.6MB，每帧全量拷贝意味着每秒上百 MB 的内存搬运，只为了"把数据换个地方"——CPU 占用和延迟一起上去了。

视频会议美颜、AR 贴纸、直播特效这类应用，帧预算里塞不下这些拷贝。

CVMetalTextureCache 因此而生：它是 Core Video 与 Metal 之间的官方桥，让像素缓冲与 Metal 纹理共享同一块内存。所有实时相机应用的第一站都是这条管线：采集 → 零拷贝上 GPU → 滤镜 → 呈现。

## What

CVMetalTextureCache 是 Core Video 与 Metal 之间的桥接缓存：把 CVPixelBuffer 包装成 Metal 可直接采样的纹理，两个框架共享同一块内存。

本实验用它搭一条完整管线——相机帧（或合成回退帧）进桥、fragment（片段着色器：GPU 上对每个像素执行的程序）四滤镜处理、CAMetalLayer 呈现。

一句话心智模型：**像素缓冲即 Metal 纹理，桥只递地址不搬数据**。可以把 CVMetalTextureCache 想象成一扇传递窗口：CPU 和 GPU 各站一边，递过去的是取货号，不是货物本身。

但窗口有前提：两边必须认同一座"仓库"，即 IOSurface-backed 内存（Apple 的跨框架共享内存格式）。相机帧天然满足；自己用 `CVPixelBufferCreate` 建的合成缓冲若不显式声明，窗口就不通——这是后面 Pitfalls 的头号坑。

## When to Use

在做实时相机应用时用它：美颜、AR 贴纸、直播特效，采集帧要逐帧上 GPU，帧预算按毫秒算。

在做视频预览或录制时用它：想加自定义 GPU 滤镜，且不能接受每帧 CPU 拷贝的延迟与占用。

在需要"永不白屏"的管线时用它：相机未授权或不可用时切合成测试帧，UI 从第一帧起就有内容。

何时不用：处理单张照片，Core Image 足够，不必建管线；处理离线视频文件，没有实时帧预算压力，拷贝成本可接受。

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| CVMetalTextureCache（本实验） | CVPixelBuffer 与 Metal 纹理共享内存 | 实时相机/视频管线 |
| 手动拷贝上 GPU | 每帧全量 memcpy 进纹理 | 一次性处理、低帧率场景 |
| Core Image | 直接消费 CVPixelBuffer，滤镜现成，自定义数学受限 | 标准滤镜需求，不写 shader |

## Quick Start

前置条件：macOS 与 Xcode 环境；脚本会把程序打包成最小 .app（携带相机权限声明）。运行：

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

核心实现代码（随后说明这段在做什么）：

```swift
// 零拷贝桥：像素缓冲 → Metal 纹理
CVMetalTextureCacheCreateTextureFromImage(
    kCFAllocatorDefault, textureCache, pixelBuffer, nil,
    .bgra8Unorm, w, h, 0, &tex)
let texture = CVMetalTextureGetTexture(tex!)
enc.setFragmentTexture(texture, index: 0)
```

- 第一段：把当前像素缓冲包装成 Metal 纹理（共享内存，不拷贝），取出的纹理直接绑定为 fragment 的输入——GPU 读的就是 CPU 写的那块内存。

合成帧的 IOSurface 声明：

```swift
let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
CVPixelBufferCreate(kCFAllocatorDefault, w, h, .bgra8Unorm, attrs as CFDictionary, &pb)
```

- 第二段：创建合成测试缓冲时显式声明 IOSurface 支持——没有这个属性，下一帧建纹理会失败（原因见 How It Works）。

## How It Works

这节沿一帧的旅程走完整条管线。你在 Quick Start 看到的 31 fps，就是这条链路在未授权环境下用合成帧跑出来的成绩。

帧的旅程分四步：

1. 相机回调到达——它发生在 `setSampleBufferDelegate` 指定的后台专用队列上；`alwaysDiscardsLateVideoFrames = true` 保证丢帧不积压，实时管线宁可丢帧不可延迟。
2. 回调内容投递回主线程（`DispatchQueue.main.async`）。
3. `CVMetalTextureCacheCreateTextureFromImage` 把像素缓冲包装成纹理，fragment 滤镜渲染。
4. 呈现到 CAMetalLayer。

四个滤镜全部在一个 fragment 函数里以 `switch (u.filter)` 分发：原图（镜像 uv.x）、黑白（亮度加权）、反色（1−c）、漫画（4 级量化 + 相邻采样差分边缘）——一次 draw 完成所有风格，切换滤镜只是换一个 uniform（CPU 每帧传给 GPU 的一小块常量数据）值。

为什么相机帧天然能进缓存而合成帧不行？AVFoundation 产出的像素缓冲必为 IOSurface-backed；`CVPixelBufferCreate` 默认不保证——显式传属性即可。这就是 Quick Start 第二段代码存在的原因。

权限生命周期决定了画面从哪来：启动时**合成帧先行**，窗口从第一帧起就有内容；随后按权限结果决定切换——authorized 停合成帧启动相机，notDetermined 弹窗（允许即切、拒绝则留在合成帧）。

之所以必须这样：**CAMetalLayer 无 drawable 呈现时就是白的**，任何等待期都必须有帧在渲染。

## Pitfalls & Q&A

**`CreateTextureFromImage` 返回 -6660 且无解释（合成缓冲）。** 现象：自己建的像素缓冲建不出纹理，错误码 -6660。原因：缓冲不是 IOSurface-backed，桥无法共享内存。

解法：`CVPixelBufferCreate` 显式传 `kCVPixelBufferIOSurfacePropertiesKey`（Quick Start 第二段代码）。相机帧天然 IOSurface，无此问题。

**CPU 锁着缓冲时建纹理，同样 -6660。** 现象：`CVPixelBufferLockBaseAddress` 持有期间调用建纹理接口失败。原因：锁定期间缓冲的内存归属不满足共享前提。解法：先填完数据、解锁，再建纹理渲染。

**多线程下偶发崩溃或花屏。** 现象：纹理创建与渲染分散在多个线程时行为不稳定。原因：这条管线对线程归属敏感。解法：纹理创建与呈现都在主线程做，相机回调统一投递 `DispatchQueue.main.async`。

**Q：为什么要把程序打包成最小 .app？** TCC（macOS 的隐私权限管理子系统，相机、麦克风等授权由它登记）权限归属需要 Info.plist（`NSCameraUsageDescription`）；裸二进制的权限会被归属到父进程（终端）且不可持久。

**Q：30fps 的渲染为什么放主线程也行？** 相机 30fps 远低于屏幕刷新，主线程渲染回调开销小；高帧率场景应换独立渲染队列 + 无锁交换。
