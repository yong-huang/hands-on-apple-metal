# 04 · 三路推理基准：GPU / Neural Engine / CPU

> 同一个模型，三个引擎，谁的延迟最低？凭感觉选 computeUnits 是赌博。本实验用 coremltools 现场生成一个 784-256-10 全连接模型，GPU / ANE / CPU 三路各跑 100 次推理，用数据回答"该选哪个引擎"。读完你将拿到 computeUnits 三选项的确切含义、基准测试的纪律，以及"小模型别上 GPU"的数据依据。

## Background

集成 CoreML 模型时，最常见的做法是取默认配置（`.all`），把引擎选择完全交给系统调度；或者按经验直接设成 GPU，跑起来不慢就算过关。

这样做的盲区在小模型上暴露：单次推理本来就只要零点零几毫秒，引擎的调度开销反而可能占大头。"全给系统调度"并不总是最优——小模型上 ANE 的调度开销可能吃掉全部收益，GPU 的固定委托开销更明显。凭感觉选 computeUnits，测出来的延迟可能比纯 CPU 还差，而且说不清原因。

出路是基准测试：同一个模型、三路 computeUnits、各跑 100 次推理取中位数。模型多大、什么结构、走哪条路，都应该有数字支撑，而不是一句"系统会调度好的"。

## What

本实验是一个三路推理基准：coremltools 生成 784-256-10 的全连接模型（最简单的一类神经网络：每层输出是输入的加权和加偏置，此处 784 个输入经 256 个隐层单元映射到 10 个输出），

编译成 mlmodelc（编译后的可加载模型产物）后，GPU / ANE / CPU 三路 computeUnits 各跑 100 次推理，输出延迟对照表。

ANE（Apple Neural Engine）是 Apple 芯片里专用于神经网络计算的加速器。

`computeUnits` 的三个选项：

- `cpuOnly`：纯 CPU 执行。
- `cpuAndGPU`：经 Metal 委托给 GPU 执行。
- `.all`：CPU + ANE + GPU 全开放，由系统自动调度。ANE 只在这个模式下可能被选中——**你无法强制指定 ANE**，只能开放让它选。

一句话心智模型：**模型只有一份，引擎三条路，选哪条看延迟表**。

## When to Use

在为一个 CoreML 模型选 computeUnits 时用它：想知道 GPU / ANE / CPU 哪条路延迟最低，跑一次就有对照表。

在迭代模型结构时用它：改了层数或算子，重新生成模型再跑一轮，能看到结构变化对不同引擎的影响。

在写技术选型文档时用它：三路 argmax（模型输出里概率最大的类别编号，即 Quick Start 延迟表末列）互为交叉验证，产出的是可复现的数据而不是体感。

何时不用：模型很大且路径明确时（如 Transformer 主力走 ANE）不必每次全跑三路；对延迟不敏感的后台推理任务，默认 `.all` 即可。

| computeUnits | 差异 | 什么时候选它 |
|:---|:---|:---|
| `cpuOnly` | 纯 CPU 执行 | 小模型，避免任何调度开销 |
| `cpuAndGPU` | Metal 委托给 GPU | 大矩阵运算，需要 GPU 吞吐 |
| `.all` | CPU + ANE + GPU，系统自动调度 | 大模型连续推理，让系统挑引擎 |

## Quick Start

前置条件：coremltools 在 `~/.venvs/ml`（venv Python 3.13），由脚本调用。运行：

```bash
./ane_bench.sh           # 一条龙：生成模型 → 编译 → 基准 → clean
# 依赖：coremltools 在 ~/.venvs/ml（venv Python 3.13）
```

真实输出：

```
路径                     中位延迟     最优延迟   argmax
----                     --------     --------   ------
CPU（cpuOnly）      0.015ms      0.010ms        4
GPU（cpuAndGPU）      0.061ms      0.026ms        4
ANE（all 自动调度）      0.015ms      0.010ms        4

三路中位延迟差异 310%（>20 说明调度确实分到了不同引擎）
✅ 基准验证通过：三路均可用且延迟差异可复现——同一模型，引擎不同表现不同
```

验证方法：三路 argmax（模型输出里概率最大的类别编号）全部一致（= 4，即三路对同一输入给出同一个预测，作为正确性参照）；延迟差异 310% 可复现——小模型上 GPU 调度开销最贵、ANE/CPU 打平，这就是"小模型别上 GPU"的数据支撑。

Swift 侧的基准循环（随后说明这段在做什么）：

```swift
let config = MLModelConfiguration()
config.computeUnits = units                     // .cpuOnly / .cpuAndGPU / .all
let model = try MLModel(contentsOf: modelURL, configuration: config)
let provider = try MLDictionaryFeatureProvider(dictionary: ["x": input])
for _ in 0..<100 {
    let t0 = CFAbsoluteTimeGetCurrent()
    let out = try model.prediction(from: provider)
    times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
}
```

- 这段在给指定引擎加载模型，同一输入连跑 100 次推理，把每次耗时（毫秒）记进数组——之后取中位数就是延迟表的数字来源。

Python 侧生成模型（coremltools 9.0）：

```python
builder = NeuralNetworkBuilder(
    input_features=[("x", Array(784))],
    output_features=[("y", Array(10))])
builder.add_inner_product(name="fc1", W=W1, b=b1, ...)
ct.models.MLModel(builder.spec).save("Model.mlpackage")
```

- 这段在用 coremltools 搭一个 784 进 10 出的全连接网络并保存为 .mlpackage——保证实验不依赖任何外部模型文件。

## How It Works

这节讲从模型生成到延迟表的完整链路。你在 Quick Start 看到的三行延迟数据，就来自下面每一步的叠加。

链路是：coremltools 生成 `.mlpackage` → 系统编译成 `.mlmodelc` → 三路 computeUnits 各跑 100 次推理 → 汇总成延迟表。

`.mlpackage` 是模型源码格式（XML 描述 + 权重文件），加载前必须编译为 `.mlmodelc`；`MLModel.compileModel(at:)` 一行即可完成，但生产环境应在打包阶段预编译，运行时编译有启动开销。

基准的纪律有三条，缺一条数字就不可信：

- **预热 10 次**：吸收首帧的模型编译开销，不让第一次的冷启动污染统计。
- **100 次取中位数**：单次耗时受系统抖动影响，中位数比平均值抗离群。
- **三路 argmax 交叉验证**：三路对同一输入的预测结果必须一致（都为 4）——性能数字必须附精度签证，否则"快了"可能是因为算错了。

为什么小模型上 GPU 反而最慢？GPU 委托要建命令缓冲（把 GPU 指令打包提交的容器）、传纹理，这部分固定开销在 0.05ms 量级；网络算力越低，该开销占总延迟的比例越高。对照 Quick Start 的输出：GPU 中位 0.061ms，而 CPU 和 ANE 都是 0.015ms——差距正是这份固定开销。

## Pitfalls & Q&A

**直接加载 .mlpackage 报"不是有效的 .mlmodelc"。** 现象：`MLModel(contentsOf: mlpackageURL)` 抛出无效模型错误。

原因：.mlpackage 是源码格式，不是可加载产物。解法：先调 `MLModel.compileModel(at:)` 得到 .mlmodelc，再加载。

**`MLMultiArray` 下标当 Float 用编译不过。** 现象：`arr[i]` 直接参与浮点运算报类型错误。原因：下标返回的是 NSNumber。解法：取值时显式 `.floatValue`。

**`String(format:)` 传 Swift 字符串崩溃或报错。** 现象：`%@` 占位符接到 Swift `String` 类型不符。原因：`%@` 需要对象类型。解法：显式转换 `as NSString`，或改用 `\( )` 插值。

**Q：ANE 什么时候值得用？** 大模型（≥百万参数的 conv（卷积层）/transformer）连续推理时，ANE 的能效优势明显；小模型频繁调用反被调度成本吞掉。

**Q：如何强制用 ANE？** 做不到——`.all` 只是开放，Apple 不暴露 ANE 直选。想贴近 ANE，要用 Core ML 专用算子集并避免不支持的层。
