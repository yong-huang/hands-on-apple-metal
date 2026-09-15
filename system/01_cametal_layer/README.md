# 01 · 脱离 MTKView：SwiftUI 里直接驱动 CAMetalLayer

> MTKView 是个好保姆——但它藏起了 drawable 调度、帧节奏、呈现时机。
> 要做自己的渲染引擎（游戏/可视化/编辑器），第一课就是把它请出去，
> 亲手驱动一枚 CAMetalLayer。本实验把它嵌进 SwiftUI 窗口，锁 60fps。

## 1. 为什么需要它

引擎化渲染的第一步：渲染循环自己掌控。MTKView 替你做了三件事（图层管理、帧调度、drawable 轮换），本实验全部手写——写完你就知道 MTKView 到底替你干了什么，也获得了任意调节帧节奏的能力。

## 2. 总览：核心机制一图看懂

![CAMetalLayer 架构](images/cametal_layer.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/metal/27_cametal_layer/images/cametal_layer.html)（或本地打开 [`images/cametal_layer.html`](images/cametal_layer.html)）。

SwiftUI 窗口驱动 DisplayLink（锁 60fps），每帧从 CAMetalLayer 取 drawable 编码渐变后呈现。一句话心智模型：**MTKView 托管的三件事全部手写：图层替换 + DisplayLink + 手动取 drawable**。

## 3. 快速开始

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

## 4. 核心概念

### 4.1 三件套的替代关系

| MTKView 托管 | 本实验的手写替代 |
|:---|:---|
| 图层管理 | `wantsLayer = true` + `layer = CAMetalLayer()` 直接替换 |
| 帧调度 | NSView `displayLink(target:selector:)` + `CAFrameRateRange(58…62, preferred 60)` |
| drawable 轮换 | 每帧 `nextDrawable()` → 渲染 → `present(drawable)` |

### 4.2 无顶点缓冲的全屏三角形

三个顶点直接越界铺满 NDC（(-1,-1)、(3,-1)、(-1,3)），片段按屏幕坐标算渐变——省掉顶点缓冲，管线最小化。后处理管线（见 22 延迟着色）用的同款技巧。

### 4.3 实测踩坑（CLT SDK 的接口缺口）

- 用 Command Line Tools 的 SDK 时，`NSView.DisplayLink` 嵌套类型与 `layerClass` 重写点解析不到——解法：属性存 `Any`、直接 `layer = CAMetalLayer()` 替换实例（等效于重写 layerClass）。
- 单文件 `@main` 应用编译要加 `-parse-as-library`，否则 swiftc 当脚本模式报"top-level code"。
- macOS 上 `preferredFramesPerSecond` 不可用，须用 `preferredFrameRateRange`。

### 4.4 drawable 的生命周期

`nextDrawable()` 可能返回 nil（三块 drawable 全在飞行中）；`present(drawable)` 必须在 commit 前调用。`framebufferOnly = true` 声明只作呈现目标，驱动可做最大优化。

## 5. 关键 API 与字段

```swift
metalLayer.drawableSize = convertToBacking(metalLayer.bounds.size)   // Retina 按 backing 像素
pass.colorAttachments[0].texture = drawable.texture                  // 直接渲进 drawable
cb.present(drawable); cb.commit()
link.preferredFrameRateRange = CAFrameRateRange(minimum: 58, maximum: 62, preferred: 60)
```

## 6. 文件结构

```
27_cametal_layer/
├── README.md                        # 本文档
├── cametal_layer.sh                 # 主演示脚本（AUTO_QUIT 自动退出）
├── cametal_layer.swift              # 实验程序：@main SwiftUI App + 渲染视图
└── images/
    ├── cametal_layer.dataflow.json  # 图源
    ├── cametal_layer.html           # 交互版
    └── cametal_layer.svg            # 双主题矢量版
```

## 7. 深入要点

- **MTKView 与 CAMetalLayer 的取舍？** 原型/教学用 MTKView；引擎化渲染要帧节奏控制权时自己驱动 layer。
- **drawable 为什么是三块？** 三缓冲：一块上屏、一块在渲染、一块供 CPU 编码——`nextDrawable` 返回 nil 就是三块都被占用。
- **displayLink 与 CADisplayLink？** NSView 实例方法返回 macOS 14+ 的新封装；老机器可用 CVDisplayLink。
- **SwiftUI 里放 Metal 的几种方式？** NSViewRepresentable 包 CAMetalLayer（本实验）、SwiftUI Shader 特效（下一项目）、MTKViewRepresentable。

## 8. 总结

渲染循环的所有权拿到了：帧节奏、呈现时机、drawable 调度全在自己手里。下一篇不写管线，直接让 SwiftUI 消费 .metal 文件——框架把路修到了门口。

→ 清单：[metal_system.md](../../docs/metal_system.md)
