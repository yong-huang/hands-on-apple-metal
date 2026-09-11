# 03 · 第一个三角形：图形管线的完整闭环

> 命令通道已经打通，但缓冲里还没有一条真正的"绘制"命令。
> 画一个三角形需要 GPU 上两条可编程着色器 + 中间一段固定管线首尾接力——这是所有图形程序的 Hello World。
> 本实验搭起整个系列复用的渲染脚手架：`MTKView` + 管线状态 + 顶点/片元着色器。

## 1. 为什么需要它

渲染一个三角形需要 6 样东西：渲染上下文（`MTKView`）、着色器函数库、渲染管线状态、顶点数据、每帧的命令编码、把结果显示出来的 drawable。少一样屏幕就是黑的。这 6 样的**连接方式**就是图形管线本身——从此你看到的每个画面，都能拆成这条流水线。

## 2. 总览：核心机制一图看懂

![渲染管线数据流](images/triangle.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/03_triangle/images/triangle.html)（或本地打开 [`images/triangle.html`](images/triangle.html)）。

顶点缓冲 → `vertex_main`（逐顶点）→ 光栅化器（硬件固定管线，插值）→ `fragment_main`（逐片元）→ drawable 呈现。一句话心智模型：**vertex 决定"形状在哪儿"，光栅化器把三角形打碎成像素，fragment 决定"每个像素什么色"**。

## 3. 快速开始

```bash
./triangle.sh               # 一条龙：build → observe → clean
./triangle.sh observe       # 窗口保持打开，关闭窗口结束
AUTO_QUIT=6 ./triangle.sh observe   # 6 秒后窗口自动退出（脚本化验证）
```

观察要点：800×600 窗口里出现一个三角形，三个角分别是红、绿、蓝，内部是平滑的颜色过渡。

验证方法：看窗口；同时控制台会打印管线就绪日志。`./triangle.sh all` 跑完后 `.build/` 已清理，目录回到实验前状态。

## 4. 核心概念

### 4.1 NDC 坐标系

顶点坐标用 **Normalized Device Coordinates**：屏幕中心是 `(0,0)`，x 向右 ∈ [-1,1]，y **向上** ∈ [-1,1]——与 AppKit 的 y 向下坐标系相反，这是 Metal 新手最常见的第一个坑。

### 4.2 渲染管线状态（`MTLRenderPipelineState`）

把"用哪个 vertex 函数 + 哪个 fragment 函数 + 像素格式"打包成一条可复用的管线。创建昂贵（要编译链接着色器）、使用廉价——所以只创建一次，每帧只做编码。

### 4.3 为什么是渐变而不是三块纯色

三个顶点各带一种颜色；光栅化器在三角形内部对颜色做**重心插值**，每个片元拿到的都是插值后的颜色。着色器里一行插值代码都不用写——这是固定管线送的。

### 4.4 着色器怎么"接住"数据

`[[buffer(0)]]`、`[[stage_in]]` 这些属性是 CPU 与 GPU 的连接暗号：Swift 侧 `setVertexBuffer(..., index: 0)` 对应着色器里 `[[buffer(0)]]`。**序号对不上，数据就送错门**。

## 5. 关键 API 与字段

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

坑清单：像素格式不一致会得到黑屏或断言；`draw` 的顶点数与缓冲不匹配只会画出残缺图形而不报错。

## 6. 文件结构

```
03_triangle/
├── README.md                     # 本文档
├── triangle.sh                   # 主演示脚本：build → observe → clean（AUTO_QUIT 自动退出）
├── main.swift                    # 入口包装：调用 runTriangle()，开窗口
├── triangle.swift                # 实验程序本体：MTKView 代理 + 管线搭建 + 内嵌着色器
└── images/
    ├── triangle.dataflow.json    # 图源（Typed JSON IR）
    ├── triangle.html             # 交互版数据流图（浏览器打开）
    └── triangle.svg              # 双主题矢量版（README 内嵌）
```

## 7. 深入要点

- **渲染一条三角形的最小对象集？** MTKView（上下文）、MTLRenderPipelineState（管线）、MTLBuffer（顶点）、每帧 RenderCommandEncoder + drawable 呈现。
- **NDC 是什么？** 与视口无关的归一化坐标，中心原点、范围 [-1,1]，y 轴向上；光栅化时再映射到实际分辨率。
- **管线状态为什么每帧不复建？** 创建涉及着色器编译链接，开销大；`MTLRenderPipelineState` 是不可变对象，建一次反复用。
- **顶点颜色为什么自动渐变？** 光栅化器对顶点属性做透视 corrected 重心插值，每个片元收到插值后的 varying 值。

## 8. 总结

三角形亮起，渲染闭环走通：数据 → vertex → 光栅化 → fragment → 屏幕。下一篇不给顶点加数，改用**索引缓冲**——用 4 个顶点画出矩形，体会 GPU 省顶点的方式。

→ 下一篇：[04 · 索引缓冲画矩形](../04_rectangle/README.md)
