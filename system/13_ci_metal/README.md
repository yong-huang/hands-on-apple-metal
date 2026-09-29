# 13 · Core Image 滤镜链与 Metal 互操作

> 用 Core Image 的现成滤镜链（CIHueAdjust → CIExposureAdjust）处理一张测试图，回读像素验证滤镜确实生效，并理清 Core Image 与 Metal 共享 GPU 纹理的互操作路径。读完本篇你会知道：什么时候用现成滤镜、什么时候自己写内核，以及两者如何在同一条管线里共存。

## Background

给图像加滤镜效果，最原始的做法是自己写逐像素算法：调色、模糊、几何校正，每种效果都要自己实现一遍（实验 08 就是这样手写了一个饱和度内核）。

痛点在于常用效果高度重复。色相旋转、曝光、锐化、人脸相关处理，几乎每个图像应用都需要，各自造轮子既费时又难调对；用 CPU 图像库跑，又在大图和实时场景下撑不住。

Core Image 因此成为 Apple 平台的默认答案：它内置上百种现成滤镜（CIFilter），滤镜可以串成链，框架自动把计算调度到 GPU 上。

而真实应用通常是混合管线——Metal 负责自定义渲染，Core Image 负责现成后处理——这时关键问题是两者能否共享 GPU 上的纹理而不来回拷贝。本实验演示的绑定方式与互操作路径，就是为这个问题准备的。

## What

Core Image 是 Apple 的高层图像处理框架，以滤镜（filter，预置的图像处理算法单元）为单位组合出处理链。

CIContext 是它的执行引擎；`CIContext(mtlDevice:)` 把引擎绑到指定的 Metal 设备（MTLDevice，GPU 及其资源的抽象入口）上，滤镜链从此与 Metal 程序共用同一个 GPU。

可以把滤镜链想象成美颜相机的预设流水线：每一步是一个现成的滤镜盒子，图像依次穿过，CIContext 是流水线的电闸。绑定 Metal 设备，相当于让这条流水线接进自家工厂的总电闸，和自建流水线（Metal 内核）共用同一套电力与传送带（显存里的纹理）。

但和自建流水线不同的是：滤镜盒子的算法改不了。效果必须是 Core Image 预置的那上百种；需要完全自定义的逐像素逻辑时，仍要回到 Metal compute（实验 08 的做法）。两条路按需求选，混合使用是常态。

## When to Use

典型场景：

- 照片、视频应用加调色滤镜：需求能被预置滤镜覆盖时，不必自己写算法。
- 给 Metal 渲染结果叠加现成效果：自动增强、模糊、色彩调整，接在自建渲染管线后面。
- 批量图片处理脚本：一条滤镜链处理一批图，GPU 自动调度。

何时不用：算法本身是自定义的（实验 08 那种），直接写 Metal compute；只做一两个简单像素变换的小任务，引入 Core Image 反而重。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| CPU 图像库（Accelerate / vDSP，Apple 的 CPU 向量化计算库及其信号与图像子库） | 留在 CPU，无 GPU 管线 | 小图、脚本批处理 |
| Core Image（不绑 Metal 设备） | 现成滤镜；与自建 Metal 管线不共享 GPU 资源 | 独立的图像处理步骤 |
| Core Image 绑 Metal 设备（本实验） | 滤镜链与 Metal 共享 GPU 与纹理，免来回拷贝 | Metal 渲染 + Core Image 后处理的混合管线 |
| Metal compute 自写滤镜（实验 08） | 逐像素逻辑完全自定义 | 预置滤镜覆盖不了的算法 |

## Quick Start

前置条件：macOS 加 Swift 编译器 `swiftc`。命令行实验，验证方法看终端输出。

```bash
./ci_metal.sh
```

预期输出（按源码推断，非实测；比例数值因系统而异，原文一次实测约 91%）：

```
=== Core Image 滤镜链 + Metal 互操作 ===
Device: <GPU 名称>
像素变化比例: <xx.x>%（<nnnnn> / 65536）
✅ Core Image 滤镜链验证通过

提示: Core Image 与 Metal 共享 GPU 纹理（CIContext(mtlDevice:)），
      后续可用 CIImage(texture:) 包装 MTLTexture 实现互操作。
```

诚实预期：判定标准是变化比例大于 50% 时打 `✅`；91% 是原文一次实测值，不同 macOS 版本可能略有差异。

## How It Works

对应源码 `ci_metal.swift`，分四步。

1. 生成测试图：CPU 填一张 256×256 的渐变像素数组，经 CGContext（CPU 端 2D 绘图上下文）包成 CGImage，再用 `CIImage(cgImage:)` 转成 Core Image 的输入。
2. 组滤镜链：先色相旋转 1.5 弧度（CIHueAdjust），再曝光加 0.5 EV（EV 指曝光挡位，CIExposureAdjust），代码见下。
3. 执行与回读：`createCGImage(finalOut, from: finalOut.extent)` 触发整条链在绑定的 Metal 设备上执行，把结果渲染成 CPU 可读的 CGImage，再从 dataProvider 拷出字节。
4. 验证：逐像素比较红通道，差值超过 10 计为"被修改"，比例大于 50% 即通过。

滤镜链的组装代码：

```swift
let hueFilter = CIFilter(name: "CIHueAdjust", parameters: [
    kCIInputImageKey: input, kCIInputAngleKey: 1.5])!
let hueOut = hueFilter.outputImage!

let expoFilter = CIFilter(name: "CIExposureAdjust", parameters: [
    kCIInputImageKey: hueOut, kCIInputEVKey: 0.5])!
let finalOut = expoFilter.outputImage!
```

- 每个滤镜的 `outputImage` 是下一个滤镜的输入图像，链条像函数组合一样串起来。
- 关键机制：此刻没有任何像素计算发生。CIImage 存的是"处理配方的描述"，不是像素数据；整条链推迟到第 3 步渲染时才一次性执行（惰性求值），框架得以把整条链整体优化调度。
- 绑定同一个 MTLDevice 后，滤镜链的中间结果全程留在 GPU；只有最后验证这一步才拷回 CPU。

互操作有两条标准路径，本实验以提示语给出方向、未实际调用：

- 入口路：`CIImage(mtlTexture:)` 把一块 MTLTexture 包成 CIImage，滤镜链可以直接处理 Metal 渲染的产物。
- 出口路：`ciContext.render(_:to:)` 把滤镜结果渲染进 MTLTexture，交给后续的 Metal 渲染步骤（Pass，一次独立的渲染过程）继续用。

你在预期输出里看到的 `像素变化比例`，就来自第 4 步的逐像素比较：测试图经过色相旋转加曝光，绝大多数像素的红通道都移出了误差带。

## Pitfalls & Q&A

坑：以为建完滤镜链就处理完了。现象是组装 CIFilter 时 CPU 几乎零占用，误以为滤镜没生效。原因是 CIImage 是惰性描述，执行发生在 `createCGImage` / `render` 调用时。解法是把渲染调用当作真正的执行点，性能问题也在这一步查。

坑：回读结果全黑或全白。现象是比较后比例异常。原因常见于色彩空间不一致：输入与输出用了不同的 RGB 色彩空间，或 CGImage 的 alpha 预乘方式（颜色分量是否已预先乘以透明度）不匹配。解法是像源码一样为输入输出统一指定 `CGColorSpaceCreateDeviceRGB()` 并声明预乘 alpha。

Q：验证为什么只比红通道？测试图的蓝通道恒为 128、alpha 恒为 255，绿通道是纵向渐变，红通道是横向渐变。红通道经过色相旋转加曝光后变化最明显，单通道足以判定"滤镜生效"。

Q：为什么是 91% 而不是 100%？部分像素红通道的变化不超过阈值 10（变化本来就小的区域），属正常现象；实验的判定线是 50%，不是 100%。

Q：生产管线也要像这样拷回 CPU 验证吗？不需要。回读是为了给"滤镜真实生效"拿独立证据；生产中绑定同一 MTLDevice 后，Core Image 与 Metal 之间的数据全程留在 GPU，只在最终呈现或导出时离开。
