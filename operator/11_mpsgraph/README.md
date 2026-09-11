# 11 · MPSGraph：把算子组合成计算图

> MPS 滤镜是"编码即调用"，MPSGraph 是另一层：声明占位符与算子节点，
> 编译成图再执行——TensorFlow-Metal 的底层就是它。
> 本实验搭一个三节点小图，跑通"建图 → 喂数据 → 回读"闭环。

## 1. 为什么需要它

二元算子组合、自动微分、模型级优化都需要图表示。MPSGraph 是苹果 ML 栈的图执行层：理解它的 placeholder → op → run 模型，就理解了 PyTorch/TF 在 GPU 上的下半场。

## 2. 总览：核心机制一图看懂

![MPSGraph 数据流](images/mpsgraph.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/11_mpsgraph/images/mpsgraph.html)（或本地打开 [`images/mpsgraph.html`](images/mpsgraph.html)）。

渐变数据喂进占位符，经 (x−0.5)×2 与 clamp 两站输出。一句话心智模型：**先声明关系，再喂数据**。

## 3. 快速开始

```bash
./mpsgraph.sh           # 一条龙
```

真实输出：

```
图结构: input → (x−0.5)×2 → clamp(0,1) → output
回读: 值域 min=0.000 max=1.000
✅ MPSGraph 计算图验证通过：3 个算子节点按图序正确执行
```

验证方法：min=0 证明 clamp 下限生效；max=1.0 证明 (1−0.5)×2 精确命中上限——整链数值无漂移。

## 4. 核心概念

### 4.1 三段式 API

`graph.placeholder(shape:dataType:)` 声明输入 → `graph.multiplication/subtraction/clamp` 建节点 → `graph.run(feeds:targetTensors:)` 执行。节点是张量代数，不是立即数运算。

### 4.2 张量数据进出

CPU 数据经 `MPSGraphTensorData(device:data:shape:dataType:)` 喂入；结果经 `results[t].mpsndarray()` 回读——NDArray 的 `readBytes(strideBytes:)` 按**行主序逐维字节步长**取数。

### 4.3 值域验证

渐变经 (x−0.5)×2 后值域应为 [−1,1]，clamp 后 [0,1]：min=0 与 max=1.0 各自锁定一个算子的行为——两个端点断言锁死整条链。

### 4.4 易错点

- 布局约定：MPSGraph 是 NHWC；喂 NCHW 数据结果"看起来对"实则错位。
- readBytes 的 stride 数组是**字节**且逐维给全，少一维直接读乱。

## 5. 关键代码

```swift
let scaled = graph.multiplication(graph.subtraction(input, half, name: "sub"), two, name: "scale")
let output = graph.clamp(scaled, min: zero, max: one, name: "output")
let results = graph.run(feeds: [input: feed], targetTensors: [output], targetOperations: nil)
```

## 6. 文件结构

```
11_mpsgraph/
├── README.md               # 本文档
├── mpsgraph.sh             # 主演示脚本
├── main.swift              # 入口包装
├── mpsgraph.swift          # 实验程序：建图 + 执行 + 值域验证
└── images/
    ├── mpsgraph.dataflow.json # 图源
    ├── mpsgraph.html          # 交互版
    └── mpsgraph.svg           # 双主题矢量版
```

## 7. 面试要点

- **MPSGraph 与 MPS 滤镜的关系？** 滤镜是预制算子（立即执行）；Graph 是声明式图（编译优化后执行），可组合可微分。
- **图执行相比逐算子编码的优势？** 编译器跨算子做融合与内存规划——16 的 mx.compile 在 MPS 世界的对应物。
- **NHWC 为什么成为 ML 默认布局？** 卷积按通道累加时内存连续，硬件向量化的访存模式更友好。

## 8. 总结

MPS 家族（滤镜/图）巡礼完毕。最后一站矩阵：商业级 GEMM 到底有多快。

→ 下一篇：[12 · MPS 矩阵乘法](../12_mps_matmul/README.md)
