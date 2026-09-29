# 02 · 线程索引与网格配置：看穿 GPU 的线程层级

> 线程索引回答"GPU 上的每个线程是谁、在哪个组"。本篇把 256 个线程的四级坐标——全局索引、组号、组内索引、组大小——全部打印成表并逐行核对，读完即可掌握 Metal 的三级坐标系，这是写规约、分块矩阵乘（tile GEMM）等任何需要线程协作的内核前的必经一步。

## Background

这节解释：向量加法里一个全局编号就够用，为什么还需要一套完整的线程层级。

在没有线程层级概念时，最朴素的做法是只给线程一个全局身份：第 0 个、第 1 个……依次编号。向量加法这类算子正好够用——每个线程处理 `A[i] + B[i]`，线程之间完全独立，谁也不用知道谁。

痛点出现在需要"线程合作"的运算里。规约（把一万个数加成一个数）要求线程先在小组内求和；矩阵乘的优化要求一组线程共同加载一块数据再各自取用。这些场景下，只靠全局编号无法回答两个问题：我和谁一组？我在组里排第几？不知道这两点，合作就无从谈起。

Metal 的答案是一套三级坐标系（grid → threadgroup → thread）加四个内建变量：派发 kernel（运行在 GPU 上的函数，见 01_vector_add）时硬件自动把每个线程的坐标填好，kernel 代码直接读取即可。

要验证这套体系真的自洽，最直接的办法就是把坐标打印成表逐行核对——这正是本实验做的事。

## What

本篇的主题是 Metal 的线程索引体系：一套三级坐标系（grid → threadgroup → thread）加四个内建变量。三个层级各司其职——grid 是本次派发的线程总量，threadgroup（线程组）是硬件调度与共享内存的分配单位，thread 是 kernel 的一次调用。

四个内建变量的分工（本实验 256 线程、每组 64、共 4 组）：

| 变量 | 含义 | 本实验取值 |
|:---|:---|:---|
| `thread_position_in_grid` | 全局第几个线程 | 0…255 |
| `threadgroup_position_in_grid` | 第几组 | 0…3 |
| `thread_position_in_threadgroup` | 组内第几个 | 0…63 |
| `threads_per_threadgroup` | 本组大小 | 64 |

一句话心智模型：**全局索引 = 组号 × 组大小 + 组内索引——线程的"门牌号"由三段坐标拼出**。

可以把这套体系想象成小区住户登记：grid 是整个小区，threadgroup 是楼栋，thread 是住户；门牌号（全局索引）= 楼栋号 × 每栋户数 + 楼栋内的房间号。但和小区不同的是，这里的"户数"由你在派发时指定，且最后一栋可能没住满（见 Pitfalls 的截短问题）。

## When to Use

这节给出判断：什么时候需要动用完整的线程坐标，什么时候一个全局编号就够。

典型场景：

- 在写需要线程协作的 kernel 时——规约的"组内求和"、矩阵乘的"分块加载"，先用组号和组内索引确定"谁和谁一组、谁负责哪块数据"。
- 在调试线程映射错乱时——输出部分对部分错，往往是个别线程的坐标映射出了问题，用"探针 kernel"（见 How It Works）把坐标打印出来逐行定位。
- 在把一维网格升到二维/三维时——先在探针实验里核对线性化公式，再套到真实算子上。

何时不用：

- 线程彼此独立的逐元素算子（如向量加法）不需要组结构，读一个 `thread_position_in_grid` 就够了；完整坐标系在协作场景才发挥价值。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| Metal 内建变量 | 硬件在启动 kernel 时自动填好四个坐标，零成本 | 任何需要线程身份的 Metal kernel |
| GCD `concurrentPerform(iterations:)` | CPU 并行，只有全局下标，没有组层级与组共享内存 | CPU 上的数据并行，线程间不需要协作 |
| CUDA `threadIdx`/`blockIdx` | NVIDIA 平台的等价三级坐标，概念一一对应 | 读 CUDA 资料或写 NVIDIA 代码时做概念对照 |

## Quick Start

前置条件：与 01 相同，一台装有 Xcode 的 Apple Silicon Mac。实现在 `thread_index.swift`：一个"探针 kernel"加 CPU 端的映射表打印与校验。

```bash
./thread_index.sh           # 一条龙：build → observe → clean
./thread_index.sh observe   # 只运行（需先 build）
```

真实输出（表格共 256 行，节选）：

```
=====> [observe] 运行算子：256 线程的四级索引映射表与校验
=== Metal Thread Index Demo ===
Device: Apple M5 Pro

  Total Threads: 256
  Threads Per Group: 64
  Number of Groups: 4

📊 Thread Index Information:
┌───────┬─────────────────────┬──────────────────────┬───────────────────────┬─────────────────┐
│ Index │ thread_position     │ threadgroup_position │ thread_position_in_tg │ threadgroup_size│
│       │ in_grid             │ in_grid              │                       │                 │
├───────┼─────────────────────┼──────────────────────┼───────────────────────┼─────────────────┤
│     0 │                   0 │                    0 │                     0 │              64 │
│     1 │                   1 │                    0 │                     1 │              64 │
  ...(共 256 行)...
  ✅ All thread indices are correct!
✅ Operator completed successfully!

实验结束。
```

验证方法：任取一行，核对 `组号 × 64 + 组内索引 == 全局索引`（如第 129 行应是组 2、组内 1）；程序本身也对全部 256 行做了断言，输出末尾的 ✅ 就是校验结论。

## How It Works

这节讲清三件事：恒等式如何在硬件层面成立、为什么需要"组"这一层、探针 kernel 怎么写。

**恒等式的自洽性**。`全局 = 组号 × 组大小 + 组内` 在输出表的每一行都成立——三级坐标系由 dispatch 参数与内建变量联动保证，不是靠约定。Quick Start 里你手工核对的任何一行，都是这条联动规则在硬件层的体现。

**为什么需要"组"这一层**。线程组是 GPU 硬件调度的真实单位：同组线程被打包进同一个执行单元，共享一块 threadgroup memory（组内线程共享的片上 SRAM，本机 32 KB，访问延迟远低于显存）。

向量加法不需要组，但规约会把"组内求和"放进共享内存做、矩阵乘会把数据块放进去复用——组是协作的前提。

**探针 kernel：让 kernel 记录自己**。本实验的 kernel 不做任何算术，只把四个内建变量的值写进输出缓冲，供 CPU 端逐行打印：

```metal
kernel void print_thread_info(device ThreadInfo* output [[buffer(0)]],
    uint tig  [[thread_position_in_grid]],           // 全局索引
    uint tgp  [[threadgroup_position_in_grid]],      // 组号
    uint tpit [[thread_position_in_threadgroup]],    // 组内索引
    uint tsize[[threads_per_threadgroup]]) {         // 组大小
    output[tig] = { tig, tgp, tpit, tsize };         // 每线程记录自己的坐标
}
```

为什么输出缓冲按 `tig`（全局索引）寻址而不是按组内索引：缓冲是全局的，每个线程在全局数组里有唯一槽位，互不覆盖——这是数据并行的"以我编号写我的槽"模式。这种"kernel 当探针"的写法是调试线程映射的通用手段。

## Pitfalls & Q&A

这节收集三个与坐标相关的坑，和一个组大小与性能的问答。

**坑 1：按恒等式核对时，不整除的场景对不上**。现象：用派发时请求的组大小去核对，最后一组算不拢。原因：`threads_per_threadgroup` 是实际生效的组大小，总数不整除时最后一组会被截短。解法：核对恒等式时使用 kernel 里读到的实际值，而不是请求值。

**坑 2：升到二维/三维网格后坐标算错**。现象：一维公式直接搬到多维，映射结果错乱。原因：四个内建变量在多维网格下都有 `.x/.y/.z` 分量，线性化公式要逐维自己乘。解法：先在一维把概念钉牢再升维（本系列 05_matmul_tiled 实验就是二维网格）。

**坑 3：打印出的"坐标"全是乱码**。现象：映射表内容不可读。原因：Swift 侧结构体与 Metal 端 `struct` 字段未对齐（两侧都需 `uint32`），缓冲按错误偏移读出垃圾值。解法：保证两侧结构体的字段类型与顺序完全一致。

**Q：线程组大小怎么影响性能？** 组大小需占满 SIMD 组（threadExecutionWidth 的倍数，SIMD 组即几十个线程同步执行同一条指令的硬件单元）。

每组太小则组数偏多、调度开销上升；太大则占用率（活跃线程占硬件可容纳线程的比例）与截短浪费上升。与 01 的"256 = 8 个 SIMD 组"是同一套准则。
