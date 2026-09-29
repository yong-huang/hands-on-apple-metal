# 03 · 第一个三角形：图形管线的完整闭环

> 画一个三角形是所有图形程序的 Hello World：它需要 GPU 上两条可编程着色器（shader，跑在 GPU 上、由你编写的两段函数）加中间一段固定管线首尾接力。本实验搭起一套可复用的渲染脚手架——`MTKView` + 管线状态 + 顶点/片元着色器，并看清从顶点数据到屏幕像素的完整数据流。

## Background

在没有 GPU 渲染管线的年代，窗口里的画面靠 CPU 逐像素算出来（软件渲染）：遍历每个像素，按形状和颜色规则算出它的颜色。一个 800×600 的窗口是 48 万个像素，每帧都要重算一遍。

痛点在动画时集中爆发：窗口再大一点、帧率再高一点，CPU 的串行计算就跟不上，画面卡顿。而算每个像素的规则高度相似、彼此独立，这种活恰恰最适合大规模并行硬件，CPU 却用不上。

GPU 应运而生地承担了这件事：CPU 只负责描述"形状的顶点在哪、每个位置用什么规则上色"，逐像素的重复计算交给 GPU 的数千核心并行完成。

渲染一个三角形需要 6 样东西：渲染上下文（`MTKView`）、着色器函数库、渲染管线状态、顶点数据、每帧的命令编码、把结果显示出来的 drawable。少一样屏幕就是黑的——这 6 样的连接方式就是图形管线本身。

## What

图形管线是 GPU 上从顶点数据到屏幕像素的固定加工流程。Metal 把其中可编程的两站（顶点着色器、片元着色器）暴露给你写代码，其余各站（裁剪、光栅化、插值）是硬件固定功能。

可以把管线想象成工厂流水线：vertex 工位决定每个零件的位置，光栅化是切割机把大块切成标准小块，fragment 工位逐块上色。但和可自由改造的流水线不同的是，"光栅化"这一站不是代码写的，它是固定硬件，插值规则改不了。

数据流一句话：顶点缓冲 → `vertex_main`（逐顶点）→ 光栅化器（硬件固定管线，插值）→ `fragment_main`（逐片元；片元即 fragment，候选像素）→ drawable 呈现。

心智模型：**vertex 决定"形状在哪儿"，光栅化器把三角形打碎成像素，fragment 决定"每个像素什么色"**。

渲染一条三角形的最小对象集：

- `MTKView`：Metal 提供的渲染视图，负责窗口与每帧调度；
- `MTLRenderPipelineState`：渲染管线状态，指定两个着色器与像素格式；
- `MTLBuffer`：顶点缓冲，GPU 可读的顶点数据内存；
- 每帧的 `MTLRenderCommandEncoder`（命令编码器，见 lab 02）与最终的 drawable 呈现。

## When to Use

这节回答：什么时候需要亲手搭这条管线，什么时候交给更高层的框架。

典型场景：

- 自定义渲染效果：想做标准框架没有提供的画面效果，从这条管线开始搭。
- 性能敏感的图形程序：游戏、可视化、模拟器画面，需要控制每个绘制细节。
- 学习与验证 GPU 环境：确认驱动、着色器编译、窗口呈现全链路可用。

何时不用：只是展示界面控件或现成图片，用 AppKit/SwiftUI；标准 2D 游戏选 SpriteKit，标准 3D 场景选 SceneKit——它们内部同样走 GPU 管线，但不必手写着色器。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| CPU 绘制 | 逐像素串行计算，实现直白；大窗口高帧率撑不住 | 小尺寸静态图、不依赖 GPU 的环境 |
| OpenGL / OpenGL ES | 老的跨平台可编程管线；Apple 平台已废弃 | 维护历史跨平台代码 |
| SpriteKit / SceneKit | 高层框架，自带管线；自定义着色器空间小 | 标准 2D/3D 内容，快速出效果 |
| Metal | 显式搭管线、写着色器；样板代码多 | 自定义效果、性能敏感渲染 |

## Quick Start

前置条件：一台支持 Metal 的 Mac，实验目录自带 `triangle.sh` 脚本；程序会打开一个窗口。

```bash
./triangle.sh               # 一条龙：build → observe → clean
./triangle.sh observe       # 窗口保持打开，关闭窗口结束
AUTO_QUIT=6 ./triangle.sh observe   # 6 秒后窗口自动退出（脚本化验证）
```

观察要点：800×600 窗口里出现一个三角形，三个角分别是红、绿、蓝，内部是平滑的颜色过渡。

验证方法：看窗口；同时控制台会打印管线就绪日志。`./triangle.sh all` 跑完后 `.build/` 已清理，目录回到实验前状态。

下面是搭建管线的核心代码，它在做的事：从内嵌源码编译着色器，把"两个着色器函数 + 像素格式"打包成一条可复用的管线。

```swift
// 从内嵌源码运行时编译着色器（无需 .metal 文件与构建阶段配置）
let library = try device.makeLibrary(source: shaderSource, options: nil)

// 管线描述符：两条着色器 + 颜色像素格式，三者缺一不可
let desc = MTLRenderPipelineDescriptor()
desc.vertexFunction = library.makeFunction(name: "vertex_main")
desc.fragmentFunction = library.makeFunction(name: "fragment_main")
desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat   // 必须与 view 一致

// 每帧编码：清屏色 + 画 3 个顶点
encoder.setRenderPipelineState(pipelineState)
encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
```

## How It Works

这节按数据流顺序拆开一帧的加工过程，共五步：

1. CPU 每帧通过命令编码器设置管线状态、绑定顶点缓冲、发出 draw 命令（`drawPrimitives` 声明"画 3 个顶点"）。
2. GPU 对每个顶点执行一次 `vertex_main`。顶点坐标用 NDC（Normalized Device Coordinates，归一化设备坐标）：屏幕中心是 `(0,0)`，x 向右 ∈ [-1,1]，y **向上** ∈ [-1,1]——与 AppKit 的 y 向下坐标系相反。
3. 光栅化器（硬件固定功能）把三角形打碎成片元（fragment，候选像素），并对顶点属性做透视校正的重心插值：按片元到三个顶点的比例混合属性值。
4. GPU 对每个片元执行一次 `fragment_main`，输出该像素的颜色。
5. 结果写入 drawable，呈现到屏幕。

你在窗口里看到的平滑颜色渐变，就来自第 3 步：三个顶点各带一种颜色，光栅化器插值后每个片元拿到的是混合色——着色器里一行插值代码都不用写，这是固定管线送的。

CPU 与 GPU 的数据交接靠属性暗号：Swift 侧 `setVertexBuffer(..., index: 0)` 对应着色器里的 `[[buffer(0)]]`，顶点着色器直接用 `[[vertex_id]]`（当前顶点的编号）从 `[[buffer(0)]]` 里按下标取顶点；

片元着色器拿到的插值结果才经 `[[stage_in]]` 接住。序号对不上，数据就送错门。

管线状态为什么只建一次：创建涉及着色器的编译与链接，开销大；`MTLRenderPipelineState` 是不可变对象，建一次反复用，每帧只做命令编码。

## Pitfalls & Q&A

坑一：窗口一片黑或直接断言崩溃。
现象是程序不报逻辑错但什么都不画。原因是管线的像素格式（颜色在内存里的存储格式）与 view 的 `colorPixelFormat` 不一致。

解法：`desc.colorAttachments[0].pixelFormat` 一律取自 `mtkView.colorPixelFormat`。

坑二：画出来的图形残缺。
现象是少一个角或整块缺失，且没有任何报错。原因是 `draw` 按传入的顶点数取数据，个数与缓冲内容不匹配时 GPU 照常执行。解法：核对 `vertexCount` 与缓冲里的顶点数一致。

坑三：三角形上下颠倒。
现象是形状对、方向反。原因是 NDC 的 y 轴向上，与 AppKit 的 y 向下坐标系相反，这是 Metal 新手最常见的第一个坑。解法：顶点坐标按 NDC 约定书写，必要时做一次 y 取反。

问：着色器一定要放在 `.metal` 文件里吗？
不一定。本实验用 `try device.makeLibrary(source:options:)` 从内嵌源码运行时编译，无需 `.metal` 文件与构建阶段配置；正式项目更常用 `.metal` 文件，由 Xcode 在构建期预编译。
