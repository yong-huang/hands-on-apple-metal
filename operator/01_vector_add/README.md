# 01 · 向量加法算子：GPU 计算的第一课

> 向量加法是最小的 GPU 算子：两个等长数组逐元素相加。本篇用它完整走一遍 CPU 与 GPU 之间的五步往返——编译 kernel、分配缓冲、编码派发、等待完成、读回验证；这套骨架与规约、矩阵乘等所有算子完全同构，读完即可看懂 MLX/MPS 这类框架内部在做什么。

## Background

这节回答一个问题：CPU 上几行就能写完的数组相加，为什么值得专门搬到 GPU 上做一遍。

默认不用 GPU 时，数组相加就是 CPU 上的一个 for 循环：按下标逐个取两个数、相加、写回。两个 1024 元素的数组，这个循环转瞬就能跑完，没有任何问题。

痛点出现在"同一种运算 × 海量数据"的场景。例如图像处理里对一千万个像素做同一种变换，或机器学习训练中每一步都对上百万个权重做逐元素运算：循环按顺序每次只处理一个元素，吞吐被限制在一个核心的执行速度上，其余核心帮不上忙——因为循环本身就是串行写的。

GPU 的设计初衷是图形渲染：屏幕上数百万个像素各自独立着色，天然是"同一个操作作用在不同数据上"。

业界随后把这种能力开放给通用计算（GPGPU，General-Purpose computing on GPU），Apple 平台上对应的框架是 Metal：开发者写好一个作用在单个元素上的函数，Metal 把它复制成千上万份，在 GPU 的众多计算单元上同时执行。

"逐元素、无依赖"的数组相加正是这种运算的最小形态，也是学 GPU 计算的第一课。

## What

算子（operator）是 GPU 计算世界的函数：输入张量（tensor，多维数组的统称）、输出张量，中间真正干活的代码叫 kernel（运行在 GPU 上的函数，本篇的 `add_arrays`）。向量加法算子做的事就一句话：`C[i] = A[i] + B[i]`，对每个下标同时成立。

一句话心智模型：**算子 = 一次"传数据过去、派线程去算、等结果回来"的往返**。

可以把这次往返想象成一次快递：把原料（数组 A、B）送到工厂（GPU），工厂里 1024 台机器（线程）同时对各自那份原料执行同一道工序，最后把成品（数组 C）收回来。

但和快递不同的是，在 Apple Silicon 的统一内存下，原料与成品可以放在 CPU 和 GPU 都能直接访问的同一块内存里，连"寄出"和"签收"的搬运都省了（机制见 How It Works）。

## When to Use

这节给出使用判断：什么场景该想起向量加法算子（以及背后的 GPU 逐元素计算），什么场景不必。

典型场景：

- 在做大数据量的逐元素变换时——数组加减乘、激活函数（机器学习模型里的逐元素非线性变换）、逐元素取对数等，把 CPU 循环换成 GPU 算子，本篇就是这条路的最小原型。
- 在写规约（reduction，把大量数据合并成少量结果——例如把一百万个数加成一个数——的算子）、矩阵乘等更复杂算子之前，先用它打通 CPU↔GPU 的数据往返骨架——后续算子只换中间的 kernel，骨架原样复用。
- 在使用 MLX、MPS 这类高层框架时，想理解其内部行为——框架底层同样要经历编译、派发、同步这些步骤，本篇是它们的显微镜。

何时不用：

- 数据量小（几十到几百个元素）时不用：派发 kernel 有固定开销，规模小时这份开销比计算本身还大，CPU 循环更快。
- 逻辑依赖复杂分支或数据本身时不宜照搬：GPU 线程之间最好互不依赖，控制流复杂的运算需要重新设计算法，或直接留在 CPU 上。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| CPU for 循环 | 单核按顺序算，无派发开销，写法最直接 | 数据量小、逻辑分支复杂 |
| Accelerate / vDSP | CPU 上的向量化数学库，自动利用 SIMD（单指令多数据，解释见 How It Works）指令，无需写 GPU 代码 | 中等数据量的逐元素运算，不想管理 GPU 资源 |
| MPS（Metal Performance Shaders） | Apple 预置的 GPU 算子库，直接调用现成 kernel | 需要的算子库里已有（卷积、矩阵乘等），不打算手写 |
| MLX | 类 NumPy 的机器学习数组框架，自动调度到 GPU | 做模型实验，关心结果而不关心算子内部 |
| 手写 Metal 算子 | 完全控制 kernel 与内存布局，可定制任意计算 | 库里没有的算子，或目标是学习 GPU 编程本身 |

## Quick Start

前置条件：一台装有 Xcode 的 Apple Silicon Mac（Metal 仅在 Apple 平台可用）。仓库内该目录自带脚本，无需额外安装依赖。

```bash
./vector_add.sh           # 一条龙：build → observe → clean
./vector_add.sh observe   # 只运行（需先 build）
```

真实输出：

```
=====> [observe] 运行算子：1024 个元素 GPU 相加 + CPU 逐元素验证
=== Metal Vector Addition Demo ===
Device: Apple M5 Pro

  Size: 1024 elements
  ✅ All 1024 results match! Vector addition successful.

✅ Operator completed successfully!

实验结束。
```

验证方法：`✅ All 1024 results match` 表明 GPU 输出与 CPU 期望逐元素一致；把 kernel 里的 `+` 改成 `-` 重跑，验证行会报出第一个 mismatch 的下标——这就是算子开发的调试闭环。

下面是派发部分的核心代码（来自 `vector_add.swift`）。这段在做什么：把编译好的计算管线和三个缓冲装进编码器，按"4 组 × 每组 256 线程"派发任务，然后阻塞等待 GPU 完成。

```swift
let pipeline = try device.makeComputePipelineState(function: function)  // 编译好的计算管线
let encoder = commandBuffer.makeComputeCommandEncoder()                 // 计算编码器
encoder.setComputePipelineState(pipeline)
encoder.setBuffer(bufferA, offset: 0, index: 0)   // 对应 kernel 的 [[buffer(0)]]
encoder.dispatchThreadgroups(MTLSize(width: 4, height: 1, depth: 1),    // 4 组
                             threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
encoder.endEncoding()
commandBuffer.commit()
commandBuffer.waitUntilCompleted()               // 唯一同步点：不等待就读是旧数据
```

## How It Works

这节按执行顺序拆开算子的五步骨架，再讲清三个机制：kernel 是什么、线程网格怎么规划、为什么没有显式的数据拷贝。

**五步骨架**：分配/传入数据 → 建管线 → 编码派发 → 同步等待 → 读回验证。任何复杂算子都套在这同一副骨架里，后续实验只是把中间的 kernel 换掉。你在 Quick Start 输出里看到的 `✅ All 1024 results match`，就来自最后一步"读回验证"。

**kernel：GPU 上的"单线程函数"**。CPU 编程模型是控制流——你写整个循环；GPU 编程模型是数据并行——你只写一个线程干的那件事，硬件把它复制 N 份同时跑：

```metal
kernel void add_arrays(device const float* inA [[buffer(0)]],
                       device const float* inB [[buffer(1)]],
                       device float* out       [[buffer(2)]],
                       uint index [[thread_position_in_grid]]) {
    out[index] = inA[index] + inB[index];
}
```

为什么这样写：`[[thread_position_in_grid]]` 让 Metal 在启动时把当前线程的全局编号填进 `index`（本实验为 0 到 1023），每个线程用这个编号算出自己负责的那个下标。

签名里还有两大暗号：`device` 地址空间标记（数据驻留显存），以及 `[[buffer(n)]]` 绑定槽——对应 Quick Start 代码里 `setBuffer(_, offset:, index:)` 的 `index`。

**线程网格的整数规划**。1024 个线程、每组 256 个 → 4 组。

通用公式 `numGroups = (count + groupSize - 1) / groupSize` 向上取整，保证 count 不是 groupSize 整数倍时也能覆盖所有元素；多余线程在 kernel 里用 `if (index >= count) return;` 自行退出——

本实验 1024 恰好整除所以省了这一步。

**组大小为什么取 256**：`pipeline.threadExecutionWidth`（本机 32）的倍数能占满 SIMD 组（SIMD——单指令多数据，即几十个线程同步执行同一条指令的硬件单元）；256 = 8 个 SIMD 组，是带宽与占用率（活跃线程占硬件可容纳线程的比例）的经验平衡点。

约束是不超过 `maxThreadsPerThreadgroup`；组过大降低调度灵活性，过小浪费组资源。

**`.storageModeShared`：统一内存的红利**。统一内存指 CPU 与 GPU 共享同一块物理内存的架构。本实验三个缓冲都用 Shared 模式：CPU `makeBuffer(bytes:)` 写入的 A/B，GPU 直接读；GPU 写完的 C，CPU 直接从 `contents()` 读。

没有显式的 upload/download——统一内存红利在算子场景的直接兑现。

## Pitfalls & Q&A

这节收集本实验最容易踩的三个坑，和两个有增量价值的问答。

**坑 1：读回的数据是旧值，且错得"看起来随机"**。原因：没有调用 `waitUntilCompleted()` 就读 `contents()`——命令是异步提交的，GPU 可能还没写完。解法：在读结果之前先等待，`waitUntilCompleted()` 是整个流程唯一的同步点。

**坑 2：`dispatchThreads` 与 `dispatchThreadgroups` 混淆**。现象：换了派发 API 后行为对不上，或在老设备上不可用。原因：前者由设备代算组数但老设备不支持，后者要自己算组数。

解法：统一使用 `dispatchThreadgroups`，配合上文"整数规划"的向上取整公式自己算组数。

**坑 3：kernel 函数名对不上，只在运行时报错**。原因：`makeFunction(name:)` 是字符串绑定，没有编译期保护。解法：保持 kernel 源码中的函数名与 `makeFunction(name:)` 参数一致，改名时全局搜索两处。

**Q：统一内存下还需要拷贝数据吗？** `storageModeShared` 缓冲双端直读，无需显式拷贝；但在离散显卡或 `private` 存储模式下仍需 blit encoder（专门在缓冲间搬数据的编码器）执行拷贝——统一内存是 Apple Silicon 的特有红利，不是 Metal 的通用保证。

**Q：CPU 加法与 GPU 加法的本质区别是什么？** GPU 把"一个循环"翻转为"一个线程的任务 + N 份硬件并行"，编程模型从控制流变为数据并行。对新手的具体含义是：思考单位从"循环怎么写"变成"单个元素怎么算、总共派多少线程"。
