# 14 · Accelerate/vDSP vs Metal 同任务对照

> 把同一个"向量缩放"任务分别用 vDSP（CPU 向量库）和 Metal compute 内核实现，各跑 100 次计时，折算成等效内存带宽对比。读完本篇你会掌握 CPU/GPU 选型的量化方法，并理解"GPU 不是总更快"的原因：小任务被固定的提交与同步开销主导。

## Background

同一个纯计算任务，CPU 和 GPU 往往都能做。没有实测数据时，选型常凭"GPU 更强"的印象直接上 GPU。

痛点在小任务场景暴露。提交 GPU 任务要走一套固定流程：打包命令、提交、等待完成；任务本身只需几十微秒时，流程时间反而占大头，总耗时比直接在 CPU 上算还长。凭印象选型，会做出更慢的方案。

正确的做法是微基准对照（microbenchmark）：同一个任务用两种方案各实现一遍，各跑多次取计时，折算成可比的指标。本实验就是一组最小对照：任务固定为"每个元素乘同一个系数"，数据量固定为 1M 个 float，比较两种方案的等效内存带宽。

## What

本实验对照的两个方案：

- vDSP：Apple 的 Accelerate 框架里的向量化计算子库，跑在 CPU 上。一个函数调用（`vDSP_vsmul`）完成全部元素缩放，调用返回即算完，没有提交与等待环节。
- Metal compute：把任务写成内核（kernel，在 GPU 上由大量线程并行执行的小函数），编码进命令缓冲（command buffer）提交给 GPU，`commit` 后 `waitUntilCompleted` 同步等 GPU 算完。

衡量指标是等效内存带宽：把耗时折算成"每秒读写了多少数据"（GB/s），两种方案就能在同一把尺子下比较。本实验任务每次迭代读 4MB、写 4MB。

可以把提交 GPU 任务想象成寄快递：包裹再小，下单和等签收的流程时间是固定的。包裹小（数据少）时流程时间占比高，自己跑腿（CPU）更快；包裹大到装满整车（几十 MB 以上），运输工具的吞吐优势（GPU 并行带宽）才显现。

但这个类比只覆盖固定开销一个维度。本实验的数据常驻 GPU 缓冲、测量中不发生 CPU 与 GPU 之间的拷贝；真实场景若还要算上数据搬运，GPU 的门槛会更高。

## When to Use

典型场景：

- 选型阶段：一个数据量已知的运算，用对照实验决定放 CPU 还是 GPU。
- 建立 性能基线：评估新机器、新系统版本时，跑一遍对照留档。
- 排查"GPU 反而更慢"的现象：先怀疑每次提交的固定开销，用本实验的方法验证。

何时不用：只求先跑通、数据量未定型时，微基准结论会随数据量失效，等定型再测；对精度要求不高时，凭任务性质粗分（小而急的给 CPU，大而整批的给 GPU）即可。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| vDSP（CPU 向量库） | 调用即执行，无提交与等待开销；带宽受 CPU 侧限制 | 小数据量、要求低延迟 |
| Metal 逐步提交 | 每次提交都有固定同步开销 | 数据量大到开销可忽略 |
| Metal 批量提交 | 多个任务合进一个命令缓冲，固定开销被摊薄 | 任务可排队，不必每步都同步等待 |
| 混合编排 | 小步骤给 CPU，大块给 GPU | 管线里两类任务并存 |

## Quick Start

前置条件：macOS 加 Swift 编译器 `swiftc`。命令行实验，验证方法看终端输出。

```bash
./vdsp_metal.sh
```

预期输出（按源码推断，非实测；三个数值随机器而异）：

```
=== vDSP vs Metal 性能对照 ===
Device: <GPU 名称>

Metal: <xx.xx> ms/100次
vDSP:  <xx.xx> ms/100次
带宽: Metal <xx> GB/s vs vDSP <xx> GB/s

✅ 对照完成：1M float 下每次 commit+wait 的同步开销（~0.25ms）主导 Metal 耗时，
   vDSP 免提交直达 350 GB/s；数据量放大到几十 MB 后 Metal 带宽优势才会显现。
```

诚实预期：原文一次实测为 Metal 约 33 GB/s、vDSP 约 350 GB/s，对应 Metal 每次迭代约 0.25 ms。你的数值会不同，但在 1M float 这个数据量下，"vDSP 明显高于 Metal"的量级关系会稳定出现。

## How It Works

对应源码 `vdsp_metal.swift`，流程五步。

1. 准备数据：生成 1M 个 float（约 4MB），`makeBuffer` 拷入 GPU 缓冲，另建输出缓冲。数据常驻 GPU，计时中不再发生 CPU 与 GPU 之间的搬运。
2. 预热 3 次：正式计时前空跑几轮，把管线编译缓存、驱动准备等一次性成本排除在测量外。
3. Metal 计时 100 次：每次都完整走一遍"编码 → 提交 → 等待"，代码见下。
4. vDSP 计时 100 次：循环调用 `vDSP_vsmul(vIn, 1, [factor], &vOut, 1, vDSP_Length(N))`——参数依次是输入、步长、系数、输出、步长、长度，一个函数调用算完 1M 个元素。
5. 折算带宽：每次迭代读写 2×N×4 = 8MB，除以单次迭代耗时（总耗时 ÷ 100），得 GB/s。

Metal 侧被计时的循环，固定开销就藏在最后两行：

```swift
let t0 = CFAbsoluteTimeGetCurrent()
for _ in 0..<100 {
    guard let cb = queue.makeCommandBuffer(),
          let enc = cb.makeComputeCommandEncoder() else { continue }
    enc.setComputePipelineState(pso)
    enc.setBuffer(inBuf, offset: 0, index: 0)
    enc.setBuffer(outBuf, offset: 0, index: 1)
    enc.setBytes(&factor, length: 4, index: 2)
    enc.dispatchThreadgroups(MTLSize(width: (N + 255) / 256, height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
}
let metalTime = CFAbsoluteTimeGetCurrent() - t0
```

- 内核本身极简：每个 GPU 线程用一维索引 `i` 算一个元素，`out[i] = in[i] * factor`。
- 派发尺寸按 `(N + 255) / 256` 个线程组（threadgroup，GPU 一次一起调度的一小队线程）、每组 256 线程计算，1M 元素正好整除；ceil 写法是通用习惯。
- `commit` 加 `waitUntilCompleted` 是每次迭代的固定成本：CPU 在这里空等 GPU。数据量小时，这个 ~0.25 ms（原文实测）比计算本身还长，这就是 Metal 带宽被拉低的全部原因。

对照结果印证心智模型：vDSP 免去了寄快递的流程，Metal 的流程费在小包裹上占了大头。

## Pitfalls & Q&A

坑：带宽算出离谱的低值。现象是测得的 GB/s 比预期低两个数量级。原因是耗时用了 100 次的总和，而字节数只按一次迭代计算。解法是按单次迭代时间折算（总耗时 ÷ 迭代次数），源码的带宽行就是这么算的。

坑：不预热，结果抖动。现象是计时结果波动大、第一次明显偏慢。原因是首次执行包含管线编译与驱动准备等一次性成本。解法是正式计时前空跑几轮，源码预热了 3 次。

Q：vDSP 测出的 ~350 GB/s 是真实内存带宽吗？严格说是等效值：数据集只有 8MB，相当一部分可能命中 CPU 侧缓存，测得的数字介于缓存带宽与主存带宽之间。对"这个任务在 CPU 上能多快"的问题，等效值正是需要的答案。

Q：对照结论怎么落地？记住两个开关：数据量（1M float 即 4MB 时 CPU 赢；几十 MB 以上 GPU 的高带宽才回本）和提交方式（能批量提交、不逐步同步等待时，Metal 的固定开销被摊薄）。两个开关都朝 GPU 有利方向拨，再选 Metal。
