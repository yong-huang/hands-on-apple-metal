# 28 · Metal 4 · MTL4 命令栈与 ML Command Encoder

> Metal 4 重构了命令提交的骨架：命令内存显式归 Allocator 管、资源绑定集中进参数表、资源常驻要登记、完成同步改用事件。读完本篇你能在新命令栈上跑通一个计算内核，并如实了解 ML（机器学习）派发当前的能力缺口。

## Background

传统 Metal 的命令提交路径是：从命令队列（Queue，按序提交命令的通道）领一个命令缓冲（CommandBuffer，录好一串 GPU 指令的容器），编码命令，commit 提交。

这套路径里框架做了大量隐式托管——命令内存由框架分配、资源绑定逐次 setBuffer、资源常驻由框架自动跟踪、完成后用 waitUntilCompleted 一等到底。

隐式托管在小型程序里是便利，在大型引擎里是成本。每帧上千次 draw（绘制调用）时，逐次绑定的重复编码命令堆积；框架替你跟踪资源生命周期，CPU 端要为不可预期的管理买单，帧时间出现无法归因的抖动；"等整条缓冲完成"的粗粒度同步，也让生产者—消费者式的流水线难以精确表达。

Metal 4 给出的答案是把这些隐式行为全部显式化：内存显式预算、绑定集中成表、常驻主动登记、同步用事件表达。MTL4 不是加几个 API，而是换了命令提交的骨架——它决定了未来很长一段时间里 Metal 代码的形态。

## What

MTL4 命令栈是 Metal 4 重构后的命令提交体系，四件套分别是：

- **Allocator**：命令内存的显式分配器，缓冲内存从这里预算化领取。
- **参数表 ArgumentTable**：资源绑定从"每次绘制逐个 setBuffer"改为"预建一张地址表，一次绑整表"。
- **驻留集 ResidencySet**：本缓冲要用到的资源必须登记，驱动据此保证它们留在 GPU 显存里。
- **共享事件 SharedEvent**：跨队列、跨 CPU/GPU 的完成信号。

ML Command Encoder 是挂在这个栈上的机器学习命令插槽，用来派发神经网络推理。

一句话心智模型：**MTL4 把"框架帮你做的"全部改成"你必须声明的"**。可以把旧栈想象成全包式酒店——水电、保洁、安保都有人代管；新栈像自己租房——每个账户自己开、每笔账自己记。但和"更麻烦"不同的是，这些声明换来的是更少的隐藏开销和可预测的调度，这正是引擎类程序要的东西。

## When to Use

- 自研引擎或长期性能敏感的项目：显式控制带来可预测的帧时间，省掉框架托管的隐性成本。
- 资源与绘制调用规模大的场景：参数表可复用、可热替换，把重复绑定命令从每帧循环里拿掉。
- 图形与机器学习混合的管线：ML Command Encoder 与计算/渲染命令在同一命令缓冲里编排。

何时不用：

- 学习阶段或小工具：传统 MTLCommandQueue 路径更简单、资料更多，概念负担小。
- 需要兼容旧系统时：MTL4 要求较新的系统版本。
- 无迁移焦虑：旧 API 与 MTL4 并存，旧代码可继续运行，迁移可以逐步做。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| 传统 MTLCommandQueue 路径 | 框架托管内存/绑定/常驻，隐式行为多 | 学习、小工具、旧系统兼容 |
| MTL4 命令栈（本文） | 全显式：Allocator + 参数表 + 驻留集 + 事件同步 | 自研引擎、性能敏感项目 |
| MTL4 栈 + ML Command Encoder | 在新栈上挂机器学习派发 | 图形与 ML 同管线的混合场景 |

## Quick Start

前置条件：macOS + Xcode 26 及以上（ML 特化构建链相关）。进入本目录运行：

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

验证方法：kernel（GPU 上大规模并行执行的小程序）结果 ×8（3 pass 串联）逐元素全对；ML 编码器可创建但缺 PipelineState（编译后的可执行 GPU 程序）——缺口被如实定位。

新栈上从建资源到等结果的核心代码只有几行：

```swift
let argTable = try device.makeArgumentTable(descriptor: atDesc)
argTable.setAddress(inBuf.gpuAddress, index: 0)    // 对应 kernel [[buffer(0)]]
cmdBuf.useResidencySet(residency)
enc.setArgumentTable(argTable)
queue.commit([cmdBuf]); queue.signalEvent(event, value: 1)
event.wait(untilSignaledValue: 1, timeoutMS: 5000)
```

这段在做什么：前三行把输入缓冲的地址写进参数表、把缓冲登记进驻留集；第四行让计算命令编码器整表绑定；最后两行提交缓冲并发出事件信号，CPU 侧等事件到达指定值。

## How It Works

按命令的生命周期走一遍，MTL4 的四件套各就各位：

1. **领内存**：`makeCommandAllocator()` 创建 Allocator，命令缓冲的内存从它显式领取——不再由框架暗中使用共享池。
2. **登记常驻**：把本缓冲会用到的资源（输入/输出缓冲等）加进 ResidencySet 并 `useResidencySet`。漏登记的资源可能被静默逐出，写入丢失且无报错。
3. **建绑定表**：`makeArgumentTable` 产出参数表，`setAddress` 把每个资源的 GPU 地址填到槽位上（槽位编号与 kernel 里的 `[[buffer(0)]]` 对应）；编码时 `setArgumentTable` 一次绑整表。
4. **显式生命周期**：`beginCommandBuffer(allocator:)` → 编码 → `endCommandBuffer()` → `queue.commit([cmdBuf])` 批量提交。没有隐式状态机，顺序完全由代码排定。
5. **事件同步**：MTL4 没有 `waitUntilCompleted`。队列 `signalEvent(event, value:)` 排在已提交缓冲之后；CPU 侧 `sharedEvent.wait(untilSignaledValue:timeoutMS:)` 等待。同一套事件语义既能做 GPU 队列之间的同步，也能做 CPU 对 GPU 的等待——细粒度的生产者—消费者表达。

你在真实输出里看到的"compute kernel 验证通过：1024 元素 ×2 全对"，就是第 2～5 步协作的结果：数据常驻、整表绑定、提交、事件等待，一个都不少。

**ML 派发的诚实边界**：`machineLearningCommandEncoder` 在本机可以创建，但真正派发网络需要 `MTL4MachineLearningPipelineState`（经 `MTL4Compiler.makeMachineLearningPipelineState` 创建）。

实测它的函数描述符必须是 GPU 特化的 Core ML（Apple 的机器学习模型格式与运行时）二进制函数（内部走 `executableWithDeviceSelection:`）。

而 coremltools 与 Xcode 的 `coremlcompiler` 命令行编译产物只有 espresso / `model.mil` 这类中间格式，不含该二进制——只有 Xcode 26 构建链在构建 app 时对模型做 Metal 特化才会生成。硬件与系统已就绪，缺口唯一且明确。

## Pitfalls & Q&A

**1. 资源写入静默丢失，读回来是旧数据。**
现象：GPU 端写入后 CPU 或后续处理阶段读到的值不对，且没有任何报错。原因：资源没有登记进 ResidencySet，可能已被驱动静默逐出——本系列在 lab 30 实测踩过。

解法：每个命令缓冲用到的全部资源都 `useResidencySet` 登记，把它当成新栈的第一习惯。

**2. 迁移代码时找不到 `waitUntilCompleted`。**
现象：旧同步代码在新栈上没有对应方法。原因：MTL4 移除了粗粒度的整缓冲等待。

解法：改用事件——队列 `signalEvent`，CPU 侧 `sharedEvent.wait(untilSignaledValue:timeoutMS:)`，见 How It Works 第 5 步。

**3. ML 编码器创建成功，却无法真正派发网络。**
现象：`makeMachineLearningCommandEncoder` 正常返回，派发阶段缺 PipelineState。

原因：派发需要 GPU 特化的 Core ML 二进制函数，命令行编译链（coremltools / coremlcompiler）产出的中间格式不含它。

解法：用 Xcode 26 构建链构建包含模型的 app，让构建过程完成 Metal 特化（本实验的定位记录）。

**Q：参数表相比逐次 setBuffer 到底省在哪？**
绑定与命令编码解耦了：同一张表可被多个命令缓冲复用，替换单个槽位不必重新编码全部绑定命令。资源多、渲染阶段多的场景里，省的是每帧重复的绑定编码量。
