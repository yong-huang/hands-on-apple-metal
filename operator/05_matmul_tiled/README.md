# 05 · 矩阵乘法 Tiled：共享内存分块复用

> Naive 慢的原因只有一个：同一个数被反复从显存读。
> Tiled 的解法优雅而朴素：把 A、B 切成 16×16 的小块搬进共享内存，
> 块内所有线程复用同一份数据——显存流量立降 16 倍。

## 1. 为什么需要它

GEMM 优化的第一课不是 simd 也不是 tensor core，而是**数据复用**。Tiled 以最小的代码增量（协作搬运 + 两道屏障）演示了"共享内存 = 手动缓存"的思想——从 90 GFLOPS 到 MPS 的 1270，路上全是这个思想的变体。

## 2. 总览：核心机制一图看懂

![Tiled GEMM 数据流](images/matmul_tiled.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/05_matmul_tiled/images/matmul_tiled.html)（或本地打开 [`images/matmul_tiled.html`](images/matmul_tiled.html)）。

A/B 的 tile 协作搬入共享内存，块内点乘累加后推进下一块。一句话心智模型：**分块搬运，块内吃干榨尽**。

## 3. 快速开始

```bash
./matmul_tiled.sh           # 一条龙
```

真实输出：

```
Tiled GEMM 512x512x512（tile=16）: 3.0 ms ≈ 90.3 GFLOPS
访存分析: Naive 每输出元素读 K×2 次；Tiled 复用后全局读量 ÷16
✅ 128 个抽样点与 CPU 一致
```

验证方法：与 04 相同的整数倍数据 + 128 点抽样。

## 4. 核心概念

### 4.1 协作搬运

每个线程搬一个元素：256 个线程恰好填满 16×16 的 tileA 与 tileB。搬运是全组合作，不是各自为战。

### 4.2 两道屏障

搬完（barrier 1）才能算；算完（barrier 2）才能覆盖搬下一块。屏障是共享内存正确性的税——漏一道就是竞态。

### 4.3 越界补零

K 不是 TILE 整数倍时，tile 尾部补 0——乘加天然吸收，无需分支。比边界分支更优雅的边界处理。

### 4.4 实测收益

512³：Naive 12 GFLOPS → Tiled 90 GFLOPS（7.5×）。对照 12 的 MPS 1270 GFLOPS——剩下的差距是寄存器分块、双缓冲与 tensor core 的领域。

## 5. 关键 API 与字段

```metal
threadgroup float tileA[TILE][TILE], tileB[TILE][TILE];
tileA[lid.y][lid.x] = (row < M && aCol < K) ? A[row*K + aCol] : 0.0;
threadgroup_barrier(mem_flags::mem_threadgroup);
for (uint k = 0; k < TILE; k++) acc += tileA[lid.y][k] * tileB[k][lid.x];
```

## 6. 文件结构

```
05_matmul_tiled/
├── README.md                       # 本文档
├── matmul_tiled.sh                 # 主演示脚本
├── main.swift                      # 入口包装
├── matmul_tiled.swift              # 实验程序：Tiled 内核 + 验证
└── images/
    ├── matmul_tiled.dataflow.json  # 图源
    ├── matmul_tiled.html           # 交互版
    └── matmul_tiled.svg            # 双主题矢量版
```

## 7. 面试要点

- **Tiling 提速的本质？** 算术强度提升：每字节访存摊到更多 FLOP，从带宽受限向算力受限移动（Roofline 视角）。
- **为什么两道 barrier 缺一不可？** 第一道保证 tile 就绪；第二道防止下一轮覆盖未被读完的数据。
- **tile 大小怎么选？** 共享内存容量 × 占用率 × 每线程工作量的联合优化；16×16 是教学与真实的常用起点。

## 8. 总结

90 GFLOPS 到手。下一篇干脆把视角拉高：亲手测出这台机器的 Roofline，让所有算子找到自己的天花板坐标。

→ 下一篇：[06 · Roofline 性能测量](../06_roofline/README.md)
