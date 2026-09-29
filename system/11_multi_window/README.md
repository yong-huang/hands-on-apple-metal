# 11 · 多窗口渲染：同一渲染器驱动多窗口

> 两个 SwiftUI 窗口各挂一块 Metal 呈现图层，用同一套 GPU 资源渲染同一场景的不同色调，关掉一个另一个不掉帧。读完本篇你能掌握 Metal 多窗口应用的标准分层：进程级资源共享，窗口级呈现独立。

## Background

桌面图形程序里，每个需要 GPU 绘图的窗口都要绑定自己的呈现层。新手最直接的做法是：开一个窗口，就完整初始化一套 GPU 资源——设备对象、命令队列、编译好的着色器程序，全套再来一遍。

痛点随窗口数量出现。同一份着色器被反复编译，启动变慢、内存翻倍；各窗口的资源互不相认，改一处绘制逻辑要同步改 N 处；窗口的打开关闭还和渲染循环搅在一起，一个窗口的生命周期问题容易波及全局。

图形编程逐渐沉淀出一个标准分层：把"昂贵的公共资源"和"每个窗口自己的呈现"拆开，前者全进程只准备一份，后者随窗口生灭。本实验就是这个分层在 Metal 下的最小实现。

## What

多窗口渲染指一个进程里多个窗口同时呈现 GPU 渲染内容。Metal 下的关键设计是把资源分成两层：

- 进程级共享：device（GPU 设备对象，一切资源的分配入口）、command queue（命令队列，提交 GPU 命令的通道）、pipeline（渲染管线状态对象，编译好的着色器加固定配置）——全进程一份。
- 窗口级独享：CAMetalLayer（把渲染结果呈现在窗口里的图层）、drawable（可上屏的纹理）、DisplayLink（与屏幕刷新同步的定时回调）——每个窗口一份。

可以把它想象成中央厨房模式：菜单和灶具（共享资源）只有一套，每个窗口是一个餐台（呈现层），各自出餐、各有节奏。

但和连锁店不同的是：灶具再共享，总产能也是一份。两个窗口同时满负荷渲染，GPU 总负载是两者之和；共享解决的是"别重复建"，不是"算力翻倍"。

## When to Use

典型场景：

- 多面板工具类应用：每个面板一个独立刷新的 3D/Metal 视图。
- 主编辑窗口加浮动预览窗：预览窗与主视图共享同一套着色器。
- 文档型应用：每个文档窗口各带一个 Metal 视图，内容不同、管线相同。

何时不用：单窗口应用不需要这层拆分，直接持有资源即可；内容是静态或低频重绘的，也不需要常驻的刷新循环，按需画一次更省电。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| 每窗口独建一套资源 | 代码最直接；着色器重复编译、内存翻倍 | 一次性原型、只有一个窗口 |
| 共享渲染器 + 独立呈现（本实验） | 资源一份、呈现互不牵连 | 多窗口渲染同类内容 |
| MTKView（MetalKit 提供的现成视图） | 系统托管 drawable 与渲染循环 | 不想手写刷新循环时 |

## Quick Start

前置条件：macOS 加 Swift 编译器 `swiftc`。GUI 实验窗口默认 8 秒后自动退出（环境变量 `AUTO_QUIT` 调整秒数）。

```bash
./multi_window.sh
```

预期输出（命令行部分，按脚本推断；期间会出现两个窗口）：

```
=====> [build] swiftc
OK

=====> [observe] 双窗口渲染
实验结束。
```

验证方法：看窗口。出现 A、B 两个 400×300 窗口，同一动画图案、不同底色（A 窗 hue=0.3 偏青，B 窗 hue=0.7 偏暖）。关闭其中一个窗口，另一个动画继续、不掉帧。

## How It Works

分四步看，对应源码 `multi_window.swift`。

1. 单例共享资源：`SharedRenderer` 用 `static let shared` 做成单例（singleton，全进程只有一份实例的对象），在首次访问时初始化一次：建 device、queue，运行时编译两个着色器并打包成 pipeline。两个窗口此后都只引用它。
2. 每窗口一份呈现：`MultiWindowMetalView` 初始化时创建自己的 CAMetalLayer，`metalLayer.device` 指向共享 device，`pixelFormat` 设为 `.bgra8Unorm`（必须与管线的像素格式一致），再装一个 DisplayLink 到主 RunLoop（应用处理事件与定时器的主循环）。
3. 每次刷新执行一次 tick（代码见下）：推进自己的时间线、取 drawable、编码并提交一帧。
4. SwiftUI（Apple 的声明式界面框架）接线：两个 `WindowGroup`（窗口组场景）分别嵌入 `MultiWindowRep(hue: 0.3)` 和 `MultiWindowRep(hue: 0.7)`，同一份视图代码靠 hue 参数区分色调。

每个窗口的刷新回调，注意"共享"与"独享"在一行代码里如何分界：

```swift
@objc func tick(_ link: Any) {
    time += 1.0 / 60.0
    guard let drawable = metalLayer.nextDrawable(),
          let cb = renderer.queue.makeCommandBuffer(),
          let enc = cb.makeRenderCommandEncoder(descriptor: MTLRenderPassDescriptor()) else { return }
    enc.setRenderPipelineState(renderer.pipeline)
    enc.setFragmentBytes(&time, length: 4, index: 0)
    enc.setFragmentBytes(&hue, length: 4, index: 1)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    cb.present(drawable)
    cb.commit()
}
```

- 来自 `renderer` 的（pipeline、queue）是共享的；来自 `metalLayer` 和自身的（drawable、time、hue）是独享的。
- `nextDrawable` 失败直接 return：该窗口被遮挡或纹理紧张时跳过本帧，只影响它自己。
- hue 走 buffer(1) 传入着色器：同一份着色器，不同窗口传不同参数，就是"同一场景的不同色调"。

验证时看到的"关一个不掉帧"，来自这个结构：关闭窗口只是移除它自己的视图与 DisplayLink，共享资源仍在，另一个窗口的回调照常执行。

## Pitfalls & Q&A

坑：窗口像素格式与管线不一致。现象是编码渲染命令时报附件像素格式不匹配的校验错误。原因是 CAMetalLayer 的 `pixelFormat` 与管线的 colorAttachment 格式必须逐位相同。解法是两处都写 `.bgra8Unorm`（或都改成同一格式）。

坑：把共享资源放进了窗口视图里。现象是窗口开多了之后启动明显变慢、内存随窗口数线性涨。原因是着色器与管线被重复编译。解法是抽成单例（本实验的 SharedRenderer），只在首次访问时初始化。

Q：一个窗口卡顿会拖垮另一个吗？两个 DisplayLink 都挂在主 RunLoop 上，CPU 侧每轮串行执行；但各自独立取 drawable、独立提交命令缓冲，一个窗口 `nextDrawable` 失败只是它自己跳帧。GPU 侧共享同一条命令队列，由系统统一调度，不存在互相阻塞的等待。

Q：`time += 1.0 / 60.0` 的时间是准的吗？不准。这是固定步长近似，没计入实际渲染耗时，长时间运行会与真实时间漂移。实验够用；要精确计时可用系统时间戳（实验 10 用的 `CFAbsoluteTimeGetCurrent` 就是这种）。
