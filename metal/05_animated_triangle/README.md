# 05 · 旋转动画三角形：Uniform Buffer 与每帧循环

> 让三角形动起来只需要每帧改一个角度，但这个角度必须高效地送到 GPU。本实验引入 Uniform Buffer（CPU 每帧写一次、GPU 每个顶点都读到的小缓冲），搭出"CPU 算参数、GPU 做变换"的每帧循环。

## Background

让画面动起来的朴素做法是：CPU 每帧重新计算所有顶点的坐标，整块重写顶点缓冲。三角形静止时顶点数据一个字节都不变，动的是"摆放方式"——旋转、平移这类变换对所有顶点一视同仁。

按朴素做法，这种全局变换也要逐顶点重算、整块重传：顶点数一多，每帧重传就是灾难；而真正变化的只有一个随时间增长的角度。变换规则全相同、数据量却随顶点数线性增长，这是典型的错配。

Uniform 机制应运而生：CPU 每帧只算一个 4×4 变换矩阵（16 个 float，64 字节）写进小缓冲，顶点坐标纹丝不动，GPU 在 vertex shader 里把每个顶点乘上矩阵。开销从"随顶点数线性增长"（O(N)）降到"恒定一份"（O(1)）。这套"每帧更新一个小缓冲"的模式是所有实时渲染的心跳。

## What

Uniform Buffer 是一块 CPU/GPU 都能访问的小缓冲，存放"对本次绘制全局相同"的数据（矩阵、时间、颜色参数）。它与顶点缓冲的分工：顶点缓冲每顶点不同，Uniform 每绘制一份。vertex shader 里用 `[[buffer(1)]]` 接住它。

可以把 Uniform 想象成 CPU 每帧递给 GPU 的一张小纸条：纸条上写着"这次按这个矩阵摆"，GPU 按纸条重画整个世界。但和随手传话不同的是，纸条必须在提交命令（`commit()`，见 lab 02）之前写好——提交之后内容就不能再指望被 GPU 看到了。

每帧循环的完整流程：CPU 侧每帧三步——`draw(in:)` 回调 → 算角度 → 矩阵写入 Uniform；GPU 侧拿矩阵变换顶点并呈现；画完立即进入下一帧，形成回环。

## When to Use

这节回答：什么样的数据该走 Uniform，什么样的数据不该。

典型场景：

- 逐帧动画参数：旋转/平移/缩放矩阵、随时间变化的相位，每帧更新一次。
- 全局渲染参数：相机位置、光照方向、颜色主题——对所有顶点或整次绘制相同的量。
- CPU 逻辑驱动画面：物理模拟、输入控制在 CPU 算出结果，经 Uniform 传给 GPU 呈现。

何时不用：逐顶点不同的数据（顶点位置、顶点色）放顶点缓冲；逐像素变化的图案交给片元着色器现算，不必经 Uniform 中转；完全不变的常量也可以直接写死在着色器里。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| CPU 绘制 | CPU 逐帧重算重画全部图形；顶点多时慢 | 顶点极少、逻辑简单的动画 |
| OpenGL / OpenGL ES | 同样提供 uniform 机制（`glUniform*`）；Apple 平台已废弃 | 维护历史跨平台代码 |
| SpriteKit / SceneKit | 动画由框架的动作/节点系统托管，不用手写循环 | 标准 2D/3D 动画 |
| Metal + Uniform | 显式管理每帧参数与提交；样板代码多 | 自定义渲染循环、性能敏感动画 |

## Quick Start

前置条件：一台支持 Metal 的 Mac，实验目录自带 `animated_triangle.sh` 脚本；程序会打开一个窗口。

```bash
./animated_triangle.sh               # 一条龙：build → observe → clean
AUTO_QUIT=6 ./animated_triangle.sh observe   # 看 6 秒旋转后自动退出
```

观察要点：三角形绕自身中心匀速旋转；关掉窗口或等 `AUTO_QUIT` 生效后程序干净退出。

验证方法：把旋转速度系数改大（源码里角度按经过时间算：`elapsedTime * 1.5`，把 1.5 乘 2），重编译后转速明显变快——证明角度确实每帧在驱动顶点。

下面是 Uniform 机制的核心代码，它在做的事：开一块只装一个 4×4 矩阵的小缓冲，每帧把矩阵覆盖写进去，编码时绑到着色器的 `[[buffer(1)]]`。

```swift
// Uniform 缓冲：装一个 Uniforms 结构体（打包矩阵的自定义类型），初始为单位矩阵（乘它等于没变换）
var initialUniforms = Uniforms(modelViewProjectionMatrix: matrix_identity_float4x4)
let uniformBuffer = device.makeBuffer(
    bytes: &initialUniforms, length: MemoryLayout<Uniforms>.size)

// 每帧：新矩阵 memcpy（整块内存拷贝）进 contents()——Shared 内存，CPU 写 GPU 读
var uniforms = Uniforms(modelViewProjectionMatrix: transformMatrix)
memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.size)

// 编码时绑到 [[buffer(1)]]——顶点缓冲占 0，Uniform 用 1
encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
```

## How It Works

这节拆开每帧循环里"纸条"的写与读。

`MTKView`（Metal 渲染视图）按显示器刷新率（60fps）调用 `draw(in:)`。每帧五步：取时间 → 算角度 → 写 Uniform → 编码绘制 → `present(drawable)`（drawable 是可提交到屏幕的渲染结果）。GPU 画完立即进入下一帧，循环回环。

每帧写入的矩阵 = 旋转矩阵 × 缩放矩阵（0.9 倍等比缩小，让三角形旋转时不转出画面），先缩放、后旋转；旋转部分是绕 Z 轴的标准形式：

```
⎡ cosθ  -sinθ  0  0 ⎤
⎢ sinθ   cosθ  0  0 ⎥      θ = 角度，随时间匀速增长
⎣   0     0    1  0 ⎦
```

矩阵在 CPU 端构造：四个矩阵列逐个手写，但用的是 simd 库（系统提供的向量化数学库）的 `simd_float4x4`；与缩放矩阵相乘后，每帧经 `memcpy` 覆盖写入 Uniform 缓冲的 `contents()`（缓冲在 CPU 侧的内存指针）。

为什么不让 CPU 直接改顶点缓冲：顶点数一大每帧重传就是灾难；Uniform 只有 64 字节，且"变换"本来就是 GPU 的主场——矩阵写一次，GPU 的数千核心并行地把每个顶点乘上去。你在窗口里看到的匀速旋转，就是每帧一张新纸条、GPU 每帧重摆一次顶点的结果。

## Pitfalls & Q&A

坑一：组合变换（先缩放再旋转之类）结果与预期不符。
现象是图形的变换顺序看起来"反了"。原因是矩阵乘法不满足交换律，`rotationMatrix * scaleMatrix` 表示"先缩放再旋转"——乘法顺序不等于视觉直觉顺序，这是 3D 数学的头号坑。解法：组合变换时从右往左读作用顺序，逐个核对。

坑二：改了 Uniform 内容但画面不生效或偶发错乱。
现象是旋转停住、或偶尔用错一帧的数据。原因是 `contents()` 写入发生在 `commit()` 之后，与 GPU 执行形成竞争。

解法：写入必须安排在 `commit()` 之前；`.storageModeShared` 下写后不必手动 flush，一致性由驱动管理。

坑三：帧率波动时旋转忽快忽慢。
原因是把动画写成增量法（每帧角度加固定值），隐含"每帧等长"的假设，帧间隔 dt 的抖动会直接变成转速波动。

本实验没踩这个坑：角度按启动至今的经过时间换算（`elapsedTime * 1.5`），帧率波动只影响画多少帧、不影响转速。自己写动画遇到忽快忽慢时，改成按经过时间（或真实 dt）换算角度即可。

问：`draw(in:)` 回调里应该做什么、不该做什么？
只做轻量的"算参数 + 编码 + 提交"。管线、缓冲等重资源的创建都应挪到初始化阶段——回调按刷新率每秒执行 60 次，任何重活都会直接拖慢帧率。
