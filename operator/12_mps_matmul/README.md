# 12 · MPS 矩阵乘法：商业级 GEMM

> 同样是 GPU 矩阵乘法：手写 kernel（在 GPU 上并行执行的小函数）实测约 90 GFLOPS（每秒十亿次浮点运算），换成 MPS 的 `MPSMatrixMultiplication` 跑出 1270 GFLOPS——约 14 倍的差距就是"商业级 GEMM 调优"的具象化。读完你能正确构造矩阵视图与乘法内核，并校准对手写代码性能水平的判断。

## Background

矩阵乘法是神经网络与图形计算中出现频率最高的运算。在厂商库出现之前，要在 GPU 上做它只能手写 kernel：自己分块（tiling，把大矩阵切成适合缓存的小块逐块计算）、自己管理线程组（threadgroup，GPU 一次调度的一组执行单元）、逐代芯片调优（手写版本见 lab 05）。

手写优化到 90 GFLOPS 已属不易，距芯片真实上限仍有一个数量级的距离；把分块、缓存复用、指令流水线每一步都做对需要多年积累，业务代码等不起这样的投入。同样的网络，性能差 14 倍可能就是可用与不可用的差别。

于是厂商把 GEMM（General Matrix Multiply，通用矩阵乘法 C = alpha·A·B + beta·C）调到接近硬件上限，以库的形式提供——

MPS（Metal Performance Shaders，苹果随 Metal 提供的调优算子库）的 `MPSMatrixMultiplication` 就是这一个。

生产代码应优先这类实现；理解它的接口抽象与性能量级，才能判断什么时候值得自己写。

## What

`MPSMatrixMultiplication` 是 MPS 提供的 GEMM 内核：给定三个矩阵，按 C = alpha·A·B + beta·C 一次算完（alpha、beta 是缩放系数，本实验取 1 和 0）。

一句话心智模型：**描述"乘什么"，不描述"怎么乘"**——你只说三块矩阵在哪、多大，分块与调度全由内核决定。

MPSMatrix 不是矩阵数据的拷贝，而是"一块内存 + 一份说明书"：`MPSMatrixDescriptor(rows:columns:rowBytes:dataType:)` 声明行列数、行距（rowBytes，每一行占的字节数，允许大于实际数据宽度）与元素类型。

可以把 MPSMatrix 想象成贴在书架上的索引卡：卡片声明从哪读、读多少，书（内存）原地不动。但和索引卡不同的是，说明书（描述符）写错不会只是"查错书"——会直接越界或读乱数据。

行距大于"列数 × 元素大小"时，同一块内存里任意一段都能声明成矩阵：子矩阵与切片因此可以零拷贝（不复制数据、直接复用原内存）。

## When to Use

典型场景：

- 神经网络的全连接层与注意力打分——一层就是一次大矩阵乘。
- 图形与机器人学中批量做坐标变换（一批顶点或位姿各乘一个变换矩阵）。
- 任何稠密（元素全部存储、不含大量零）矩阵的 C = A×B，需要接近硬件上限的吞吐。

何时不用：矩阵很小（几十乘几十）时，内核启动开销占比高，CPU 的 Accelerate 可能更快；需要乘完立刻接自定义操作，或使用特殊内存布局与量化格式时，MPS 没有入口（见 Pitfalls）。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| MPSMatrixMultiplication | 厂商调优内核，接口只描述形状 | 通用 GEMM 的默认选择 |
| 手写 Metal kernel | 完全可控，可融合自定义后续步骤 | 特殊融合、特殊布局/量化格式 |
| Accelerate / BLAS | CPU 实现，无需 GPU 管线 | 小矩阵、CPU 管线内 |
| MLX / Core ML | 更上层的框架，面向整个模型 | 不想手摆矩阵、直接跑网络 |

## Quick Start

前置条件：macOS + Xcode 的 Swift 工具链，机器支持 Metal。在实验目录下运行：

```bash
./mps_matmul.sh           # 一条龙
```

真实输出（节选）：

```
…（程序标题与 Device 信息行省略）
MPS GEMM 1024x1024x1024: 1.7 ms ≈ 1270 GFLOPS
  （对照：05 实验手写 Tiled 512³ ≈ 90 GFLOPS——商业内核与手写内核的差距就是优化空间）
✅ 128 个抽样点与 CPU 一致
```

计时与 GFLOPS 每次运行会有小幅波动，量级不变。

验证方法：整数倍数据 + 128 点 CPU 抽样——性能再强也不豁免正确性。"整数倍"指输入数据取 0.25/0.5 这类粗粒度倍数，浮点累加没有舍入误差，CPU 抽样比对才是精确对答案；"128 点抽样"指等间隔抽取 128 个结果元素与 CPU 逐个比对。

关键实现（完整程序见 `mps_matmul.swift`）：

```swift
let gemm = MPSMatrixMultiplication(device: device, transposeLeft: false, transposeRight: false,
                                   resultRows: M, resultColumns: N, interiorColumns: K, alpha: 1, beta: 0)
gemm.encode(commandBuffer: cb, leftMatrix: matA, rightMatrix: matB, resultMatrix: matC)
```

这段在做什么：第一行声明"要算的形状"——结果 M 行 N 列、内积维度 K、缩放系数 alpha/beta，两个 transpose 参数为 false 表示 A、B 都不转置；第二行把"读 A 和 B、写 C"记入命令缓冲（command buffer，提交给 GPU 的指令队列）。

分块大小、精度策略、芯片代际适配全由 MPS 决定。

## How It Works

一次调用分四步：用描述符把内存缓冲（`MTLBuffer`，CPU 与 GPU 共享的一块内存）声明成矩阵视图；构造 `MPSMatrixMultiplication` 并给出形状与 alpha/beta；`encode` 登记进命令缓冲；提交后 GPU 执行。

1024×1024×1024 指三个矩阵的维度：A 为 1024×1024，B 为 1024×1024，内积维度 K 也是 1024，结果 C 同为 1024×1024。

性能数字怎么读：1270 GFLOPS 是 1024³ 的 FP32（32 位浮点数格式）结果。芯片算力上限（每秒能完成的浮点运算理论上限）实测 2.26 TFLOPS（每秒万亿次浮点运算，见 lab 06）——MPS 跑出了理论值的 56%，而且这个数字还随矩阵增大继续爬升：矩阵越大，固定开销摊得越薄。

你在输出里看到的 `1.7 ms ≈ 1270 GFLOPS` 就是"内核全托管"的直接产出——手写要逐层对齐的分块与流水线，这里是库的默认行为。

alpha 与 beta 的语义：计算式是 C = alpha·A·B + beta·C。beta=0 就是纯乘法；beta≠0 时既有结果 C 参与累加——多层并行累加、residual 连接（把输入直接加回输出的网络结构）的批量实现都靠它。

## Pitfalls & Q&A

**第一次计时明显偏慢？** 现象：首轮耗时远高于后续轮次。原因：首轮包含内核选择与编译等一次性开销。解法：先空跑一两轮预热，再开始计时。

**复用结果缓冲后数值越算越大？** 现象：结果矩阵的数值随调用次数不断增长。原因：beta≠0 时 C 参与累加（C = alpha·A·B + beta·C），旧结果没清零就叠了上去。解法：纯乘法传 beta=0；确需累加语义时，保证 C 的初值符合预期。

**MPSMatrix 为什么是视图而不是值？** 与纹理同源的设计：内存归调用方管理，语义由描述符声明——这是零拷贝切片的前提，也意味着描述符写错时没有任何保护。

**什么时候值得自己写 GEMM？** 需要非常规融合（自定义 epilogue——乘完立刻接的附加操作，如激活函数）、特殊内存布局或量化格式时；通用 FP32 场景先用 MPS。
