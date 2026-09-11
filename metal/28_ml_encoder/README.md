# 28 · Metal 4 · MTL4 命令栈与 ML Command Encoder

> Metal 4 不是加几个 API，而是重构了命令提交的骨架：
> 命令内存显式归 Allocator、资源绑定集中进参数表、资源常驻要登记、
> 完成同步改用事件。本实验在新栈上真跑一个 kernel，并如实探测 ML 派发的缺口。

## 1. 为什么需要它

MTL4 的架构变化决定了未来十年的 Metal 代码形态：更少的隐式行为、更贴近硬件的调度。在旧 API 还能用的今天理解新栈，等于提前拿到下一代引擎的入场券。

## 2. 总览：核心机制一图看懂

![MTL4 命令栈](images/ml_encoder.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/28_ml_encoder/images/ml_encoder.html)（或本地打开 [`images/ml_encoder.html`](images/ml_encoder.html)）。

命令栈 → 参数表绑定 → kernel 执行 → SharedEvent 同步，ML 编码器作为插槽被如实探测。一句话心智模型：**MTL4 把"框架帮你做的"全部改成"你必须声明的"**。

## 3. 快速开始

```bash
./ml_encoder.sh               # 一条龙
```

真实输出：

```
✅ Allocator + MTL4Queue + CommandBuffer 就绪
✅ MTL4 栈 compute kernel 验证通过：1024 元素 ×2 全对
⚠️ ML Command Encoder 可创建，但派发网络还需 Xcode 26 编译的 Core ML 包
   （.mlpackage → PipelineState）——这是本实验未完成 ML 派发的唯一原因，硬件与系统已就绪
```

验证方法：kernel 结果 ×8（3 pass 串联）逐元素全对；ML 编码器可创建但缺 PipelineState——缺口被如实定位。

## 4. 核心概念

### 4.1 三大架构变化

**Allocator**：命令缓冲的内存显式预算化管理；**ArgumentTable**：资源绑定从"每 draw setBuffer"变为"预建地址表"；**ResidencySet**：用到的资源必须登记，漏登记的写入被静默丢弃（30 实测踩过）。

### 4.2 显式生命周期

`beginCommandBuffer(allocator:)` → 编码 → `endCommandBuffer()` → `queue.commit([buf])` 批量提交。没有隐式状态机，一切自己排。

### 4.3 完成同步

MTL4 没有 `waitUntilCompleted`：队列 `signalEvent(event, value:)` + CPU 侧 `sharedEvent.wait(untilSignaledValue:timeoutMS:)`——事件既做 GPU 间同步也做 CPU 等待。

### 4.4 ML 派发的诚实边界

`machineLearningCommandEncoder` 可创建，但派发网络需要 `MTL4MachineLearningPipelineState`，它来自**已编译的 Core ML 包**——该编译目前只有 Xcode 26 构建链提供。硬件与系统已就绪，缺口唯一且明确。

## 5. 关键 API 与字段

```swift
let argTable = try device.makeArgumentTable(descriptor: atDesc)
argTable.setAddress(inBuf.gpuAddress, index: 0)    // 对应 kernel [[buffer(0)]]
cmdBuf.useResidencySet(residency)
enc.setArgumentTable(argTable)
queue.commit([cmdBuf]); queue.signalEvent(event, value: 1)
event.wait(untilSignaledValue: 1, timeoutMS: 5000)
```

## 6. 文件结构

```
28_ml_encoder/
├── README.md                   # 本文档
├── ml_encoder.sh               # 主演示脚本
├── main.swift                  # 入口包装：调 runMlEncoder()
├── ml_encoder.swift            # 实验程序：MTL4 栈 + 验证 + ML 探测
└── images/
    ├── ml_encoder.dataflow.json# 图源
    ├── ml_encoder.html         # 交互版
    └── ml_encoder.svg          # 双主题矢量版
```

## 7. 面试要点

- **MTL4 相比传统 Metal 的本质变化？** 从"框架托管"转向"显式声明"：内存、绑定、常驻、同步全部显式化。
- **ArgumentTable 解决什么？** 资源绑定与命令编码解耦：表可复用、可热替换，大幅减少重复绑定命令。
- **ResidencySet 漏登记会怎样？** 资源可能被静默逐出——写入丢失且无报错（实测），必须养成登记习惯。
- **为什么取消 waitUntilCompleted？** 细粒度事件模型让生产者-消费者（CPU/GPU/队列间）用同一套语义表达。

## 8. 总结

新命令栈跑通，ML 缺口定位明确。下一篇把"最后一公里"的探测做完：Shader ML 的编译链到底卡在哪。

→ 下一篇：[29 · Shader ML](../29_shader_ml/README.md)
