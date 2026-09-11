# 03 · 向量点积规约：两阶段树形归并

> 向量加法里线程各干各的；点积却要"把一百万个数加成一个"——
> 线程之间第一次需要**协作**。共享内存与树形规约就此登场，
> 这是所有归约类算子（求和/最大值/直方图）的公共骨架。

## 1. 为什么需要它

一百万个数求和，朴素并行（一锁一加）会让锁吃掉全部收益。树形规约把 O(N) 步串行变成 log₂(N) 步并行——理解它才能理解 simdgroup、threadgroup 内存为什么存在。

## 2. 总览：核心机制一图看懂

![规约数据流](images/reduction.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/03_reduction/images/reduction.html)（或本地打开 [`images/reduction.html`](images/reduction.html)）。

1M 乘积经组内树形规约压成 4096 个部分和，再经组间收尾归一。一句话心智模型：**组内做树，组间做接力**。

## 3. 快速开始

```bash
./reduction.sh           # 一条龙：build → observe → clean
```

真实输出：

```
GPU 规约结果: 58710732.00（CPU 期望 58712152.00，相对误差 2.42e-05）
两阶段: 4096 组 × 256 线程 → 4096 部分和 → 1；耗时 2.3 ms
✅ 规约验证通过
```

验证方法：浮点求和有顺序误差，用相对误差（<1e-3）而非逐位比对判定——这也是浮点算子验证的通用准则。

## 4. 核心概念

### 4.1 threadgroup 内存

`threadgroup float scratch[256]`：同组线程共享的片上黑板，比显存快一个量级。规约的中间值全部住在它里面，显存流量只有首尾两次。

### 4.2 树形规约

每步把相邻两个数相加，活跃线程数减半：256→128→…→1，共 8 步。每步一个 `threadgroup_barrier`——没人能用半成品相加。

### 4.3 两阶段接力

1M 数据一组建不完：第一阶段 4096 组各交一个部分和；第二阶段单组收尾，每线程先**跨步串行累加 16 个**再树形归并——第一版漏了这步只加了前 256 个，结果差 94%（实测踩过的坑）。

### 4.4 交错取数

`data[gid]` 相邻线程取相邻地址——合并访存（coalescing）让带宽打满。取数模式错了，规约再对也快不起来。

## 5. 关键 API 与字段

```metal
threadgroup_barrier(mem_flags::mem_threadgroup);   // 组内同步点
for (uint s = lsize/2; s > 0; s >>= 1) {
    if (lid < s) scratch[lid] += scratch[lid + s];
    threadgroup_barrier(mem_flags::mem_threadgroup);
}
```

## 6. 文件结构

```
03_reduction/
├── README.md                    # 本文档
├── reduction.sh                 # 主演示脚本
├── main.swift                   # 入口包装
├── reduction.swift              # 实验程序：双内核规约 + 验证
└── images/
    ├── reduction.dataflow.json  # 图源
    ├── reduction.html           # 交互版
    └── reduction.svg            # 双主题矢量版
```

## 7. 面试要点

- **为什么树形而不是串行累加？** 串行 N 步 vs 树形 log N 步，且每步并行度递减适配硬件。
- **barrier 的语义？** 组内全员到齐才放行；漏写会产生竞态（读到未写入的 scratch）。
- **两阶段为什么必要？** 全局同步不可得（组间无 barrier），用"部分和 + 二次内核"代替全局同步。
- **相对误差阈值怎么定？** 浮点加法不结合，1M 元素误差 ~1e-5 量级正常；逐位相等反而是错的检验。

## 8. 总结

线程学会了协作。下一篇用同样的线程映射做矩阵乘法的朴素版，为 Tiled 优化立起对照基线。

→ 下一篇：[04 · 矩阵乘法 Naive](../04_matmul_naive/README.md)
