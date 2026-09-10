# 05 · 旋转动画三角形：Uniform Buffer 与每帧循环

> 顶点坐标写死在缓冲里，画面就永远静止——总不能每帧重建整个顶点缓冲。
> 让三角形动起来只需要每帧改一个角度，但这个角度必须高效地送到 GPU。
> 本实验引入 Uniform Buffer：CPU 每帧写一次，GPU 每个顶点都读到。

## 1. 为什么需要它

动画 = 时间驱动的状态更新。旋转三角形只需要一个随时间变化的旋转矩阵，它对**所有顶点一视同仁**——这类"每帧全局量"就是 Uniform。它把 CPU 的动画逻辑与 GPU 的顶点变换解耦：CPU 只算 4×4 矩阵（16 个 float），顶点坐标纹丝不动，GPU 负责把每个顶点乘上矩阵。这套"每帧更新一个小缓冲"的模式是所有实时渲染的心跳。

## 2. 总览：核心机制一图看懂

![每帧渲染循环](images/animated_triangle.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/05_animated_triangle/images/animated_triangle.html)（或本地打开 [`images/animated_triangle.html`](images/animated_triangle.html)）。

上泳道 CPU 每帧三步：`draw(in:)` 回调 → 算角度 → 矩阵写入 Uniform；下泳道 GPU 拿矩阵变换顶点；底部虚线是"下一帧"回环。一句话心智模型：**CPU 每帧只递一张小纸条（矩阵），GPU 按纸条重画整个世界**。

## 3. 快速开始

```bash
./animated_triangle.sh               # 一条龙：build → observe → clean
AUTO_QUIT=6 ./animated_triangle.sh observe   # 看 6 秒旋转后自动退出
```

观察要点：三角形绕自身中心匀速旋转；关掉窗口或等 `AUTO_QUIT` 生效后程序干净退出。

验证方法：把旋转速度系数改大（程序里 `angle` 增量乘 2），重编译后转速明显变快——证明角度确实每帧在驱动顶点。

## 4. 核心概念

### 4.1 Uniform Buffer 是什么

一块 CPU/GPU 都能访问的小缓冲，存"对本次绘制全局相同"的数据（矩阵、时间、颜色参数）。与顶点缓冲的区别：顶点缓冲**每顶点不同**，Uniform **每绘制一份**。vertex shader 里用 `[[buffer(1)]]` 接住它。

### 4.2 绕 Z 轴的旋转矩阵

```
⎡ cosθ  -sinθ  0  0 ⎤
⎢ sinθ   cosθ  0  0 ⎥      θ = 角度，随时间匀速增长
⎣   0     0    1  0 ⎦
```

矩阵在 CPU 端构造（本实验手写，未引 SIMD 库），每帧覆盖写入 Uniform 缓冲的 `contents()`。

### 4.3 `MTKView` 驱动的回调循环

`MTKView` 按显示器刷新率（60fps）调用 `draw(in:)`；每帧：取时间 → 算角度 → 写 Uniform → 编码绘制 → `present(drawable)`。GPU 画完立即进入下一帧——这就是 2.6 图里的回环边。

### 4.4 易错点

- **矩阵乘法顺序**：`rotationMatrix * scaleMatrix` 表示"先缩放再旋转"。矩阵乘法顺序 ≠ 视觉直觉顺序，是 3D 数学的头号坑。
- 写 `contents()` 后不必手动 flush（`.storageModeShared` 下由驱动管理一致性），但必须发生在 `commit()` 之前。
- 帧间角度用"增量"而非"绝对时间"重算时注意 dt 抖动——本实验用增量法。

## 5. 关键 API 与字段

```swift
// Uniform 缓冲：只装一个 4x4 矩阵（16 个 Float）
let uniformBuffer = device.makeBuffer(length: 16 * MemoryLayout<Float>.size)

// 每帧：矩阵直接覆盖进 contents()（Shared 内存，CPU 写 GPU 读）
let ptr = uniformBuffer.contents().bindMemory(to: Float.self, capacity: 16)
for (i, v) in matrix.enumerated() { ptr[i] = v }

// 编码时绑到 [[buffer(1)]]——顶点缓冲占 0，Uniform 用 1
encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
```

为什么不让 CPU 直接改顶点缓冲：顶点数一大每帧重传就是灾难；Uniform 只有 64 字节，且"变换"本来就是 GPU 的主场。

## 6. 文件结构

```
05_animated_triangle/
├── README.md                              # 本文档
├── animated_triangle.sh                   # 主演示脚本：build → observe → clean（AUTO_QUIT 自动退出）
├── main.swift                             # 入口包装：调用 runAnimatedTriangle()
├── animated_triangle.swift                # 实验程序本体：每帧循环 + 旋转矩阵 + Uniform
└── images/
    ├── animated_triangle.workflow.json    # 图源（Typed JSON IR）
    ├── animated_triangle.html             # 交互版流程图（浏览器打开）
    └── animated_triangle.svg              # 双主题矢量版（README 内嵌）
```

## 7. 面试要点

- **Uniform 与顶点属性的区别？** 顶点属性每顶点一份、由光栅化插值；Uniform 每绘制一份、全局相同，适合矩阵/时间等帧级参数。
- **动画为什么不能靠重写顶点缓冲？** CPU 重算并重传全部顶点开销大；传一个矩阵让 GPU 在 vertex shader 里做变换，数据量从 O(N) 降到 O(1)。
- **`draw(in:)` 回调里应该做什么、不该做什么？** 只做轻量的"算参数 + 编码 + 提交"；管线/缓冲等重资源的创建都应挪到初始化阶段。
- **矩阵乘法顺序为什么重要？** 矩阵不满足交换律，`M_rotation * M_scale` 与反序结果不同；组合变换时从右往左读才是作用顺序。

## 8. 总结

画面动起来了：Uniform 是 CPU 每帧递给 GPU 的"参数纸条"，驱动循环让这一幕每秒重演 60 次。下一篇换个思路——不改顶点也不递纸条，让**片元着色器逐像素作画**，画一块棋盘格。

→ 下一篇：[06 · 片元着色器棋盘格](../06_chessboard/README.md)
