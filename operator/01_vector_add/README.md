# 01 · 向量加法算子：GPU 计算的第一课

> 渲染线（metal/01-09）解决了"怎么画"；从本实验起换一条主线——用 GPU **算数据**。
> 算子（operator）是 GPU 计算世界的函数：输入张量、输出张量、中间是 kernel。
> 向量加法是最小的算子，但 CPU↔GPU 往返的五步套路，与 GEMM、融合内核完全同构。

## 1. 为什么需要它

两个 1024 元素的数组相加，CPU 一个 for 循环就完事——但这个"玩具"恰好完整暴露了 GPU 计算的全部参与方：编译 kernel、分配缓冲、编码派发、等待完成、读回验证。后面所有算子实验（规约、矩阵乘、INT4 GEMV）都只是把中间的 kernel 换掉，**五步骨架一个字不改**。它是你理解 MLX/MPS 内部在做什么的显微镜。

## 2. 总览：核心机制一图看懂

![向量加法时序](images/vector_add.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/01_vector_add/images/vector_add.html)（或本地打开 [`images/vector_add.html`](images/vector_add.html)）。

CPU 写入 A/B → 编码 pipeline 与缓冲 → `dispatchThreadgroups 4×256` → commit → GPU 上 1024 个线程并行执行 `C[i]=A[i]+B[i]` → waitUntilCompleted → CPU 读回逐元素比对。一句话心智模型：**算子 = 一次"传数据过去、派线程去算、等结果回来"的往返**。

## 3. 快速开始

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

## 4. 核心概念

### 4.1 kernel：GPU 上的"单线程函数"

```metal
kernel void add_arrays(device const float* inA [[buffer(0)]],
                       device const float* inB [[buffer(1)]],
                       device float* out       [[buffer(2)]],
                       uint index [[thread_position_in_grid]]) {
    out[index] = inA[index] + inB[index];
}
```

你写的不是"1024 次循环"，而是**一个线程干的一件事**；GPU 把它复制 1024 份并行执行。`device` 地址空间标记（数据驻留显存）与 `[[buffer(n)]]` 绑定槽是 kernel 签名的两大暗号。

### 4.2 线程网格的整数规划

1024 线程、每组 256 → 4 组。通用公式 `numGroups = (count + groupSize - 1) / groupSize` 向上取整，保证 count 不是 groupSize 整数倍时也覆盖所有元素（多余线程在 kernel 里用 `if (index >= count) return;` 自行退出——本实验 1024 恰好整除所以省了）。

### 4.3 `.storageModeShared`：统一内存的红利

三个缓冲都用 Shared 模式：CPU `makeBuffer(bytes:)` 写入的 A/B，GPU 直接读；GPU 写完的 C，CPU 直接从 `contents()` 读。没有显式的 upload/download——这是渲染线 01 就铺垫过的统一内存在算子场景的兑现。

### 4.4 易错点

- 忘 `waitUntilCompleted()` 就读结果：读到的是**旧数据**，而且错得"看起来随机"。
- `dispatchThreads` 与 `dispatchThreadgroups` 混淆：后者要自己算组数，前者设备代计算（老设备不支持）。
- kernel 名字与 `makeFunction(name:)` 不一致只在运行时报错——字符串绑定没有编译期保护。

## 5. 关键 API 与字段

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

为什么组大小取 256：`pipeline.threadExecutionWidth`（本机 32）的倍数能占满 SIMD 组；256 = 8 个 SIMD 组，是带宽与占用率的经验平衡点。

## 6. 文件结构

```
01_vector_add/
├── README.md                        # 本文档
├── vector_add.sh                    # 主演示脚本：build → observe → clean
├── main.swift                       # 入口包装：MetalContext（device+queue）+ 调 runVectorAdd
├── vector_add.swift                 # 实验程序本体：add_arrays kernel + 五步骨架
└── images/
    ├── vector_add.sequence.json     # 图源（Typed JSON IR）
    ├── vector_add.html              # 交互版时序图（浏览器打开）
    └── vector_add.svg               # 双主题矢量版（README 内嵌）
```

## 7. 面试要点

- **CPU 加法与 GPU 加法的本质区别？** GPU 把"一个循环"翻转为"一个线程的任务 + N 份硬件并行"；编程模型从控制流变为数据并行。
- **统一内存下还需要拷贝数据吗？** `storageModeShared` 缓冲双端直读，无需显式拷贝；但离散显卡/`private` 模式仍需 blit encoder 搬运——统一内存是 Apple Silicon 的特有红利。
- **线程组大小怎么选？** 不超过 `maxThreadsPerThreadgroup`，取 `threadExecutionWidth` 倍数（本机 32 的 8 倍 = 256）以占满 SIMD；过大降低调度灵活性，过小浪费组资源。
- **算子的五步骨架是什么？** 分配/传入数据 → 建管线 → 编码派发 → 同步等待 → 读回验证；任何复杂算子都套在同一骨架里。

## 8. 总结

最小的算子跑通，GPU 计算的五步心跳建立。每个线程只看到一个 `index`——它是怎么来的？下一篇派 256 个线程把四级坐标（全局/组号/组内/组大小）全部打印出来，看穿 GPU 的线程层级。

→ 下一篇：[02 · 线程索引与网格配置](../02_thread_index/README.md)
