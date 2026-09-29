# 11 · MPSGraph：把算子组合成计算图

> MPSGraph 是苹果的计算图框架（计算图：把每步计算记成节点、依赖关系记成边，整体编译后再执行）——TensorFlow-Metal 的底层就是它。读完你能跑通"建图 → 喂数据 → 回读"闭环，并理解声明式图执行与逐算子立即调用的区别。

## Background

用 MPS 滤镜或手写 kernel（在 GPU 上并行执行的小函数）做计算时，每一步都是立刻执行的独立调用，步骤之间的关系只存在于代码的书写顺序里，框架看不到全局。

痛点出现在更复杂的需求上：多步算子（一个明确定义的计算步骤，如减法、缩放）组合、自动微分（自动算出梯度——每个参数对结果的影响方向，训练神经网络的核心步骤）、模型级优化。逐算子立即执行没有全局视图，框架既不能跨步骤融合计算（融合：把多个算子合并成一次 GPU 计算，省掉中间结果的写回与再读取），也无法自动求导。

计算图表示为此而生：先把全部计算声明成一张图，再整体编译执行。MPSGraph 是苹果 ML 栈的图执行层，TensorFlow-Metal 的底层就是它——理解它的"先声明占位符和算子节点、再喂数据执行"模型，就理解了 PyTorch/TensorFlow 在 GPU 上的执行层。

本实验搭一个三节点小图，跑通"建图 → 喂数据 → 回读"闭环。

## What

MPSGraph 是 Metal Performance Shaders 家族中的计算图框架：用占位符（placeholder，只声明形状与数据类型、暂不绑定数据的输入空位）和算子节点声明一张图，喂数据后整体执行。图中流动的是张量（tensor，多维数组，标量、向量、矩阵的统一推广）。

一句话心智模型：**先声明关系，再喂数据**。可以把建图想象成先印好一张带空格的公式考卷，`run` 时才把具体数值填进空格。但和考卷不同的是，图声明一次就能反复执行，每次喂不同的数据。

本实验的图只有三站：`input → (x−0.5)×2 → clamp(0,1) → output`，其中 clamp（把值夹在 [min, max] 区间内，低于取 min、高于取 max）。

## When to Use

典型场景：

- 在苹果设备上部署自定义神经网络——TensorFlow-Metal 即构建在 MPSGraph 之上。
- 一串张量运算需要自动微分时，把计算声明成图，求导交给框架。
- 多步组合计算希望编译器统一做融合与显存规划，而不是逐步手动编码。

何时不用：单步标准图像滤镜，用 MPS 滤镜直接编码更省事；小规模数组逻辑，CPU 或 Accelerate 更简单；图结构需要频繁变化时，每次重建图有开销——声明一次、反复执行才划算。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| MPS 滤镜 | 预制算子，立即编码执行 | 单步标准图像操作 |
| MPSGraph | 声明式计算图，编译后执行，可组合可微分 | 多步张量计算、需要自动微分或整图优化 |
| 手写 Metal kernel | 逐像素完全可控 | 差异化逻辑、现成库没有的原语 |
| Core ML | 更上层的模型部署框架 | 拿现成模型文件做 App 内推理 |
| MLX | 面向研究的数组框架，API 接近 NumPy | 原型与研究，非 App 内集成 |

## Quick Start

前置条件：macOS + Xcode 的 Swift 工具链，机器支持 Metal。在实验目录下运行：

```bash
./mpsgraph.sh           # 一条龙
```

真实输出（节选）：

```
…（程序标题与 Device 信息行省略）
图结构: input → (x−0.5)×2 → clamp(0,1) → output
输出值域: min=0.000 max=1.000（期望 min≈0，max≈0.98，渐变经拉伸后触底不封顶）
✅ MPSGraph 计算图验证通过：3 个算子节点按图序正确执行
```

验证方法：min=0 证明 clamp 下限生效；max=1.0 证明 (1−0.5)×2 精确命中上限——整链数值无漂移。

核心实现三行（完整程序见 `mpsgraph.swift`）：

```swift
let scaled = graph.multiplication(graph.subtraction(input, half, name: "sub"), two, name: "scale")
let output = graph.clamp(scaled, min: graph.constant(0.0, dataType: .float32), max: graph.constant(1.0, dataType: .float32), name: "output")
let results = graph.run(feeds: [input: feed], targetTensors: [output], targetOperations: nil)
```

这段在做什么：前两行只是在图里"挂"节点，此刻没有任何计算发生——把 input 减 half、乘 two，再夹到 [0,1]；第三行 `run` 才真正执行：把喂数据 `feed` 绑到占位符 `input`，请求输出 `output`。

## How It Works

一次完整执行分四步：

1. 建图：`graph.placeholder(shape:dataType:)` 声明输入空位，再用算子方法挂节点；
2. 喂数据：CPU 数组经 `MPSGraphTensorData(device:data:shape:dataType:)` 包装成图能吃的张量数据；
3. 执行：`graph.run(feeds:targetTensors:)` 触发编译，编译器此时可跨算子做融合与内存规划——与 MLX（苹果面向机器学习的数组计算框架，见 lab 14）的 `mx.compile`（把一段计算先整体编译、再执行的接口）思路相同，先编译、再整体执行；
4. 回读：`results[output].mpsndarray()` 拿到 NDArray（多维数组容器），再用 `readBytes(strideBytes:)` 按行主序逐维字节步长取数。

值域验证的数学：渐变输入 x ∈ [0,1]，经 (x−0.5)×2 后值域应为 [−1,1]，再经 clamp(0,1) 应为 [0,1]。min=0.000 锁定 clamp 的下限行为；max=1.000 来自 (1−0.5)×2=1.0，证明缩放精确命中上限。

你在输出里看到的两个端点各自来自链条上不同的一站——两端都对，整条链的数值就无漂移。

节点为什么不是立即计算：`graph.multiplication(...)` 返回的是张量引用而非数值，它只在图里记录"输出等于输入们的这个运算"。正因如此，同一张图可以换不同的 `feed` 反复 `run`，编译器也才能看到全图做整体优化。

## Pitfalls & Q&A

**结果"看起来对"实则错位？** 现象：数值大体正常，逐元素比对大面积错位。原因：布局约定不符——MPSGraph 默认 NHWC（批次、高、宽、通道四维的排列顺序），喂入 NCHW（通道排在第二维）的数据后每个维度的含义全变。解法：喂数据前把维度重排成 NHWC。

**readBytes 回读的数据错乱？** 现象：取出的数组内容与预期不符。原因：stride（字节步长，沿每一维前进一个元素要跨过的字节数）数组必须按行主序逐维给全、单位是字节，少一维直接读乱。解法：每一维的字节步长一个不落地给出。

**NHWC 为什么成为 ML 默认布局？** 卷积（小窗口在数据上滑动做加权求和的运算）按通道累加时，NHWC 下同通道数据内存连续，对硬件向量化的访存模式更友好。

**建图会不会反而更慢？** 建图与编译是一次性成本，图声明一次即可反复 `run`，执行次数越多摊到每次的开销越小；只有单次性的小计算不值得建图。
