# 04 · 三路推理基准：GPU / Neural Engine / CPU

> 同一个模型，三个引擎，谁的延迟最低？凭感觉选 computeUnits 是赌博。
> 本实验用 coremltools 现场生成一个 784-256-10 全连接模型，
> GPU / ANE / CPU 三路各跑 100 次推理，用数据回答"该选哪个引擎"。

## 1. 为什么需要它

CoreML 的 `computeUnits` 有三个选项，但"全给系统调度"并不总是最优——小模型上 ANE 的调度开销可能吃掉全部收益。基准测试给出可复现的对照数据：模型多大、什么结构、走哪条路，都应该有数字支撑。

## 2. 总览：核心机制一图看懂

![三路基准数据流](images/ane_bench.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/system/04_ane_bench/images/ane_bench.html)（或本地打开 [`images/ane_bench.html`](images/ane_bench.html)）。

coremltools 生成 mlpackage → 系统编译成 mlmodelc → 三路 computeUnits 各跑 100 次推理出延迟表。一句话心智模型：**模型只有一份，引擎三条路，选哪条看延迟表**。

## 3. 快速开始

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

验证方法：三路 argmax 全部一致（= 4，CPU 参照）；延迟差异 310% 可复现——小模型上 GPU 调度开销最贵、ANE/CPU 打平，这就是"小模型别上 GPU"的数据支撑。

## 4. 核心概念

### 4.1 computeUnits 三选项

`cpuOnly`（纯 CPU）、`cpuAndGPU`（Metal 委托执行）、`.all`（CPU+ANE+GPU 全开放）。ANE 只在 `.all` 下由系统自动调度——**你无法强制指定 ANE**，只能开放让它选。

### 4.2 mlpackage 与 mlmodelc

`.mlpackage` 是模型源码格式（XML + 权重），加载前需编译为 `.mlmodelc`。`MLModel.compileModel(at:)` 一行搞定——但生产环境应在打包阶段预编译，运行时编译有启动开销。

### 4.3 基准的纪律

预热 10 次吸收首帧编译；100 次取中位数抗抖动；三路 argmax 互为交叉验证——性能数字必须附精度签证。

### 4.4 易错点

- 直接 `MLModel(contentsOf: mlpackageURL)` 会报"不是有效的 .mlmodelc"——.mlpackage 是源码不是产物。
- `MLMultiArray` 下标取值是 NSNumber（`arr[i].floatValue`），直接当 Float 用编译不过。
- `String(format:)` 的 `%@` 要传 NSString——Swift 字符串需显式转换。

## 5. 关键代码

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

Python 侧生成模型（coremltools 9.0）：

```python
builder = NeuralNetworkBuilder(
    input_features=[("x", Array(784))],
    output_features=[("y", Array(10))])
builder.add_inner_product(name="fc1", W=W1, b=b1, ...)
ct.models.MLModel(builder.spec).save("Model.mlpackage")
```

## 6. 文件结构

```
04_ane_bench/
├── README.md                    # 本文档
├── ane_bench.sh                 # 主演示脚本：生成模型 → 编译 → 基准
├── gen_model.py                 # coremltools 模型生成（需 ~/.venvs/ml）
├── ane_bench.swift              # 基准程序：三路 × 100 次推理
├── Model.mlpackage              # 运行时生成（clean 时删除）
└── images/
    ├── ane_bench.dataflow.json  # 图源
    ├── ane_bench.html           # 交互版
    └── ane_bench.svg            # 双主题矢量版
```

## 7. 深入要点

- **为什么小模型 GPU 反而最慢？** GPU 委托要建命令缓冲、传纹理——固定开销 0.05ms 量级；网络算力越低该开销占比越高。
- **ANE 什么时候值得用？** 大模型（≥百万参数的 conv/transformer）连续推理时，ANE 的能效比碾压；小模型频繁调用反被调度成本吞掉。
- **如何强制用 ANE？** 做不到——`.all` 只是开放；Apple 不暴露 ANE 直选。想贴近 ANE 要用 Core ML 专用算子集并避免不支持的层。

## 8. 总结

三路基准给出了"该选哪个引擎"的可复现答案。下一篇开始把 AI 推理接入实时画面——Vision 人脸检测 + Metal 马赛克。

→ 下一篇：[05 · Vision 人脸马赛克]（清单 docs/metal_system.md 项目 5，待实现）
MDEOF
echo "README 04 done"