# 01 · 脱离 MTKView：SwiftUI 里直接驱动 CAMetalLayer

> MTKView 替你托管了 Metal 渲染循环的大部分细节；本实验把这些细节全部收回自己手里：在 SwiftUI 窗口里直接驱动一枚 CAMetalLayer，锁 60fps 画一个随时间流动的渐变。读完你将能自己完成 drawable 调度、帧节奏控制和呈现时机安排。

## Background

在 Metal（Apple 的 GPU 编程框架）应用里，最常见的起点是 MTKView——MetalKit 提供的 Metal 专用视图。你实现一个 `draw(in:)` 回调，剩下的图层管理、帧调度、drawable 轮换（多块屏幕缓冲的轮流使用）都由它托管。

这层托管在原型阶段是便利，在引擎阶段是天花板。设想你在做一个可视化引擎：想让交互时跑满 120fps、静止时降到 30fps 省电，或者让呈现时机与物理模拟步长严格对齐。MTKView 不提供这些控制点，帧节奏和呈现时机都由它决定。

出路在于认识 CAMetalLayer：Core Animation（Apple 负责把图层合成到屏幕的界面框架）中真正接收 Metal 渲染结果的图层，MTKView 只是包在它外面的一层壳。绕过这层壳直接驱动它，渲染循环的所有权就回到自己手里。本实验把这件事完整走一遍。

## What

CAMetalLayer 是 Core Animation 的一个图层类，负责持有可供 GPU 渲染的缓冲（drawable），并把渲染结果呈现到屏幕。本实验的做法是：在 SwiftUI 窗口里用一个普通 NSView 挂上 CAMetalLayer，然后手写完整的渲染循环。

一句话心智模型：**MTKView 托管的三件事全部手写：图层替换 + DisplayLink + 手动取 drawable**。可以把 MTKView 想象成包工头，你从"等派活"变成"自己站上三道工位"。

但类比到这就失效了：MTKView 的托管并不只是省代码，它还处理了不少边界情况——drawable 用尽、窗口尺寸变化——手写之后这些都要自己兜底。三道工位的对应关系如下：

| MTKView 托管 | 本实验的手写替代 |
|:---|:---|
| 图层管理 | `wantsLayer = true` + `layer = CAMetalLayer()` 直接替换 |
| 帧调度 | NSView `displayLink(target:selector:)` + `CAFrameRateRange(58…62, preferred 60)` |
| drawable 轮换 | 每帧 `nextDrawable()` → 渲染 → `present(drawable)` |

## When to Use

在写自己的渲染引擎（游戏、可视化、编辑器）时用它：引擎需要按自己的节奏决定何时渲染、何时呈现，而不是被动响应框架回调。

在需要动态调帧率时用它：目标帧率由你持有的 displayLink 控制，可以按负载随时改 `preferredFrameRateRange`。

在排查渲染问题或教学时用它：直接面对 drawable 与命令缓冲（GPU 命令的打包容器，Quick Start 第三行有逐行说明），能看清 MTKView 平时藏掉的那部分机制。

何时不用：原型、demo、一次性验证选 MTKView 更省事；纯界面特效（不管理 3D 场景）选 SwiftUI Shader；图像滤波处理选 Core Image。这些都是更简单的替代。

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| MTKView | 托管图层、帧调度、drawable 轮换 | 原型与教学，不需要帧节奏控制权 |
| CAMetalLayer + NSViewRepresentable（本实验） | 三件事全手写，帧节奏与呈现时机自控 | 引擎化渲染 |
| MTKViewRepresentable | MTKView 桥接进 SwiftUI | SwiftUI 里要 MTKView 的完整托管 |
| SwiftUI Shader | 框架消费 `.metal` 文件做界面特效，无渲染循环 | 纯视觉特效，不建引擎 |

## Quick Start

前置条件：macOS 与 Swift 命令行编译环境（脚本内部调用 swiftc，无需 Xcode 工程）。运行：

```bash
./cametal_layer.sh           # 一条龙（AUTO_QUIT=<秒> 自动退出）
```

真实输出：

```
编译完成 → .build/cametal_layer
fps: 54.6（55 帧提交成功）
fps: 60.0（61 帧提交成功）
fps: 60.0（60 帧提交成功）
...
实验结束。
```

窗口内渐变随时间流动。验证方法：每秒打印的 fps 稳定 60.0（首秒 54.6 为启动抖动）；代码里 os_signpost 每帧打点，`xctrace` 可直接查看帧时间线——两个证据都指向"每帧都在提交"。

核心实现代码如下（随后逐行说明这段在做什么）：

```swift
metalLayer.drawableSize = convertToBacking(metalLayer.bounds.size)   // Retina 按 backing 像素
pass.colorAttachments[0].texture = drawable.texture                  // 直接渲进 drawable
cb.present(drawable); cb.commit()
link.preferredFrameRateRange = CAFrameRateRange(minimum: 58, maximum: 62, preferred: 60)
```

- 第一行：把 drawable 的分辨率设为视图的 backing 像素尺寸（Retina 屏的物理像素），画面不糊。
- 第二行：把渲染管线（GPU 从三角形到逐像素上色的一整套处理流程）的目标纹理直接指向 drawable 自带的纹理，渲染结果就是呈现内容，无需拷贝。
- 第三行：在命令缓冲（GPU 命令的打包容器，commit 后整体交给 GPU 执行）上声明"提交后呈现这块 drawable"，再把整个命令缓冲交给 GPU。
- 第四行：给 displayLink 设定目标帧率——偏好 60fps，允许在 58~62 之间浮动。

## How It Works

这节按一帧的生命周期走完整个循环。你在 Quick Start 看到的 `fps: 60.0`，就来自下面这套机制每秒稳定运转约 60 次。

1. **帧驱动**：displayLink 回调触发，节奏与屏幕刷新对齐。
2. **取 drawable**：调用 `nextDrawable()` 向 CAMetalLayer 要一块空闲缓冲；拿不到（返回 nil）就跳过本帧。
3. **编码命令**：创建命令缓冲与渲染命令编码器（往命令缓冲里写入具体绘制指令的对象），目标纹理设为 drawable 的纹理，画一个全屏三角形。
4. **呈现与提交**：`present(drawable)` 挂上呈现意图，`commit()` 把命令缓冲交给 GPU。注意顺序——`present` 必须在 `commit` 之前调用，否则提交后就没有呈现动作了。

全屏三角形是这里的关键技巧：三个顶点 `(-1,-1)`、`(3,-1)`、`(-1,3)` 直接越界铺满 NDC（归一化设备坐标，把屏幕映射为 -1 到 1 的坐标系），只有落在屏幕内的部分会被光栅化（光栅化：把三角形覆盖的区域换算成一个个像素）。

片段着色器（对屏幕上每个像素执行一次、决定该像素颜色的小程序）按像素坐标算渐变，顶点缓冲（描述三角形各顶点位置的内存块）整个省掉。后处理管线（见 22 延迟着色）用的同款技巧。

drawable 的生命周期由三缓冲支撑：一块正在上屏、一块正在被 GPU 渲染、一块供 CPU 编码下一帧。三块全被占用时 `nextDrawable()` 返回 nil，这正是第 2 步要处理 nil 的原因。

`framebufferOnly = true` 向驱动声明这块纹理只作呈现目标、不会被读回，驱动因此可以做最大优化。窗口尺寸变化时，`layout()` 会重新按 backing 像素同步 `drawableSize`，保证 Retina 下清晰度不丢。

## Pitfalls & Q&A

**用 Command Line Tools 的 SDK 编译时，DisplayLink 相关类型解析不到。** 现象：`NSView.DisplayLink` 嵌套类型与 `layerClass` 重写点均解析失败。

原因：CLT SDK 的 Swift 接口缺这些声明。解法：属性存 `Any`（源码中的 `frameLink`），并直接 `layer = CAMetalLayer()` 替换实例——等效于重写 `layerClass`。

**单文件 `@main` 应用编译报 "top-level code"。** 现象：swiftc 把单文件当脚本模式编译，直接失败。原因：脚本模式不允许 `@main`。解法：编译参数加 `-parse-as-library`。

**macOS 上 `preferredFramesPerSecond` 不可用。** 现象：想给 displayLink 锁帧率时找不到这个常见属性。原因：平台接口差异，macOS 侧不提供它。

解法：设置 `preferredFrameRateRange`，即 Quick Start 第四行代码的 `CAFrameRateRange`。

**`nextDrawable()` 偶发返回 nil。** 现象：某一帧取不到缓冲。原因：三块 drawable 全在飞行中（机制见 How It Works 的三缓冲）。解法：跳过本帧、等下一次 displayLink 回调，不要阻塞等待。

**Q：displayLink 与 CADisplayLink 什么关系？** NSView 的 `displayLink(target:selector:)` 实例方法返回的是 macOS 14+ 的新封装；老系统上可用 CVDisplayLink 达到同样效果。
