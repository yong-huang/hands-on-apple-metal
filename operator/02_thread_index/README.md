# 02 · 线程索引与网格配置：看穿 GPU 的线程层级

> 上一篇每个线程靠 `index` 领到了自己的活，但这个 index 是谁发的、怎么编的，还是黑盒。
> 把 256 个线程的四级坐标全部记录下来逐行核对，层级模型就再无秘密。
> 这是写规约、tile GEMM、任何需要"线程协作"的内核前的必经一步。

## 1. 为什么需要它

向量加法里线程彼此独立；但规约要"组内合作"、GEMM 要"分块加载"——这些都要求线程清楚自己在**组里的位置**和**组的编号**。Metal 的答案是一个三级坐标系（grid → threadgroup → thread）加四个内建变量。亲手把 256 个线程的坐标打印成表并逐行验证，比背十遍文档都牢。

## 2. 总览：核心机制一图看懂

![线程层级架构](images/thread_index.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/operator/02_thread_index/images/thread_index.html)（或本地打开 [`images/thread_index.html`](images/thread_index.html)）。

256 线程的 grid 划成 4 个 threadgroup（每组 64），每个 kernel 调用把三个坐标写进输出缓冲。一句话心智模型：**全局索引 = 组号 × 组大小 + 组内索引——线程的"门牌号"由三段坐标拼出**。

## 3. 快速开始

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

## 4. 核心概念

### 4.1 四个内建变量的分工

| 变量 | 含义 | 本实验取值 |
|:---|:---|:---|
| `thread_position_in_grid` | 全局第几个线程 | 0…255 |
| `threadgroup_position_in_grid` | 第几组 | 0…3 |
| `thread_position_in_threadgroup` | 组内第几个 | 0…63 |
| `threads_per_threadgroup` | 本组大小 | 64 |

恒等式 `全局 = 组号 × 组大小 + 组内` 在每一行都成立——这就是三级坐标系的自洽性。

### 4.2 为什么需要"组"这一层

线程组是 GPU 硬件调度的真实单位：同组线程被打包进同一个执行单元，**共享一块 threadgroup memory**（本机 32 KB，01 实验里查过），还能用 simdgroup 原语互相通信。向量加法不需要组，但规约把"组内求和"放共享内存里做、GEMM 把 tile 放进去复用——组是协作的前提。

### 4.3 kernel 的"记录自己"模式

本实验的 kernel 不做算术，只把四个内建变量的值写进输出缓冲的对应槽位——让 CPU 端能逐行打印。这种"kernel 当探针"的写法是调试线程映射的通用手段。

### 4.4 易错点

- `threads_per_threadgroup` 是**实际生效**的组大小；当总数不整除时最后一组会被截短，按恒等式核对时要用实际值。
- 二维/三维网格时四个变量都有 `.x/.y/.z` 分量，线性化公式要自己乘——先在一维把概念钉牢再升维（路线图 op05 的 Tiled GEMM 是二维）。
- Swift 侧结构体与 Metal 端 `struct` 必须字段对齐（都是 `uint32`），错位读出的"坐标"会全是乱码。

## 5. 关键 API 与字段

```metal
kernel void print_thread_info(device ThreadInfo* output [[buffer(0)]],
    uint tig  [[thread_position_in_grid]],           // 全局索引
    uint tgp  [[threadgroup_position_in_grid]],      // 组号
    uint tpit [[thread_position_in_threadgroup]],    // 组内索引
    uint tsize[[threads_per_threadgroup]]) {         // 组大小
    output[tig] = { tig, tgp, tpit, tsize };         // 每线程记录自己的坐标
}
```

为什么输出缓冲按 `tig`（全局索引）寻址而不是按组内索引：缓冲是全局的，每个线程在全局数组里有唯一槽位，互不覆盖——数据并行的"以我编号写我的槽"模式。

## 6. 文件结构

```
02_thread_index/
├── README.md                               # 本文档
├── thread_index.sh                         # 主演示脚本：build → observe → clean
├── main.swift                              # 入口包装：MetalContext + 调 runThreadIndex
├── thread_index.swift                      # 实验程序本体：探针 kernel + 256 行映射表 + 校验
└── images/
    ├── thread_index.architecture.json      # 图源（Typed JSON IR）
    ├── thread_index.html                   # 交互版架构图（浏览器打开）
    └── thread_index.svg                    # 双主题矢量版（README 内嵌）
```

## 7. 深入要点

- **Grid / Threadgroup / Thread 的关系？** grid 是本次派发的线程总量，threadgroup 是硬件调度与共享内存的分配单位，thread 是 kernel 的一次调用；三者由 dispatch 参数与内建变量联动。
- **全局索引怎么由局部坐标算出？** `组号 × threads_per_threadgroup + 组内索引`；多维时逐维展开再线性化。
- **为什么需要 threadgroup memory？** 组内线程共享一块片上 SRAM（本机 32 KB），访问延迟远低于显存；规约、tile GEMM 靠它做数据复用与协作。
- **线程组大小对性能的影响？** 需占满 SIMD 组（threadExecutionWidth 的倍数）；每组太小则组数多、调度开销大，太大则占用率与截短浪费上升。

## 8. 总结

线程的"门牌号"体系已看穿：全局、组号、组内三个坐标拼出每个线程的身份。至此算子编程的两块地基——命令骨架（op01）与线程模型（op02）——都已夯实。路线图后续项目（规约、Naive/Tiled GEMM、Roofline、MPS、MLX，见 `docs/operator.md`）将在这两块地基上逐层起楼。

→ 返回系列总目录：[hands-on-apple-metal](../../README.md)
