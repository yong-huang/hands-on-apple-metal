# 04 · 矩阵乘法 Naive：基线内核

> GEMM 是深度学习的心脏（占大模型 80% 算力）。优化之前，
> 先写一个"慢但对"的版本：每线程算输出矩阵的一个元素。
> 它的价值不在快，而在**作为一切优化的对照组**。

## 1. 为什么需要它

没有基线的优化是盲目的。Naive GEMM 结构最简（一眼看懂数据映射），同时暴露全部性能问题（重复访存）——05 的 Tiled、12 的 MPS 对照都以它为原点。

## 2. 总览：核心机制一图看懂

![Naive GEMM 数据流](images/matmul_naive.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/04_matmul_naive/images/matmul_naive.html)（或本地打开 [`images/matmul_naive.html`](images/matmul_naive.html)）。

A 的行与 B 的列在 2D 线程网格里点乘成 C。一句话心智模型：**线程坐标 = 输出坐标**。

## 3. 快速开始

```bash
./matmul_naive.sh           # 一条龙
```

真实输出：

```
每线程组最大线程数（内核）: 1024
Naive GEMM 256x256x256: 2.9 ms ≈ 11.7 GFLOPS
✅ 128 个抽样点与 CPU 逐位一致
```

验证方法：系数取"整数倍的 0.25/0.5"，乘加无舍入误差 → CPU/GPU 结果应**逐位一致**（抽样 128 点）——比相对误差更严格的验证。

## 4. 核心概念

### 4.1 2D 线程网格

`gid.x` 对应列、`gid.y` 对应行，16×16 线程组铺满 M×N。边界检查 `row >= M || col >= N` 在非整除时保护越界。

### 4.2 数据映射与访存分析

每个输出元素读 A 一行 + B 一列 = 2K 次访存。全矩阵 2×M×N×K 次——A 的每一行被读 N 遍、B 的每一列被读 M 遍。**这就是 11.7 GFLOPS 的全部原因**。

### 4.3 逐位一致的验证设计

数据初始化用 `k % 13 * 0.25` 这类二进制精确小数，乘加次序虽不同但无舍入差 → 可用 `==` 比对。验证强度要与数据特性匹配。

## 5. 关键 API 与字段

```metal
float acc = 0;
for (uint k = 0; k < dims.z; k++)
    acc += A[row * dims.z + k] * B[k * dims.y + col];   // 行主序索引
C[row * dims.y + col] = acc;
```

`dims` 用 `setBytes` 传 3×uint32——比三个独立参数更整洁。

## 6. 文件结构

```
04_matmul_naive/
├── README.md                        # 本文档
├── matmul_naive.sh                  # 主演示脚本
├── main.swift                       # 入口包装
├── matmul_naive.swift               # 实验程序：朴素内核 + 逐位验证
└── images/
    ├── matmul_naive.dataflow.json   # 图源
    ├── matmul_naive.html            # 交互版
    └── matmul_naive.svg             # 双主题矢量版
```

## 7. 面试要点

- **Naive GEMM 的瓶颈？** 带宽：每 FLOP 摊到 1 字节访存，算术强度 0.5——远低于 Roofline 拐点。
- **为什么用逐位一致验证？** 构造二进制精确数据时无舍入差，最严格的验证零成本。
- **线程网格为什么 16×16？** 覆盖 TILE 语义、占用率与 shared memory 用量的折中；上限受 maxTotalThreadsPerThreadgroup 约束。

## 8. 总结

基线立住：11.7 GFLOPS。下一篇用共享内存分块复用，看它翻几倍。

→ 下一篇：[05 · 矩阵乘法 Tiled](../05_matmul_tiled/README.md)
