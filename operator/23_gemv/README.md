# 23 · 自定义 GEMV 内核

> LLM 解码期（batch=1）的算力大头是 GEMV：y = W·x。
> 每线程组负责一行：组内跨步分摊乘加、共享内存树形规约——
> 03 的规约骨架直接复用，与 MLX 原生实现数值一致。

## 1. 为什么需要它

GEMV 是"规约 × GEMM"的合体练习：既要有每行的点乘结构，又要有组内协作。跑通它，自定义内核就从"玩具"进入了"生产形态"。

## 2. 总览：核心机制一图看懂

![GEMV 数据流](images/gemv.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/operator/23_gemv/images/gemv.html)（或本地打开 [`images/gemv.html`](images/gemv.html)）。

W 逐行喂给线程组，组内规约出每行的点积写进 y。一句话心智模型：**一行一组，组内吃干**。

## 3. 快速开始

```bash
./gemv.sh           # 一条龙
```

真实输出：

```
自定义 GEMV vs numpy 最大绝对差: 2.29e-05
自定义 GEMV: 0.182 ms | MLX 原生 matmul: 0.105 ms
✅ 验证通过：数值一致，性能同量级（原生内核有 simd 优化，教学版不必追平）
```

验证方法：与 numpy 矩阵乘的最大绝对差 < 1e-3；性能与原生同量级即可（教学版以正确性为先）。

## 4. 核心概念

### 4.1 一组一行

`gid = threadgroup_position_in_grid` 定位行，行内 `lid` 跨步分摊 K 维乘加——组内天然无竞争（各攒各的部分和）。

### 4.2 组内规约

部分和写入 `threadgroup float s[256]`，树形归并到 s[0]——03 的骨架原样复用，验证了骨架的可迁移性。

### 4.3 标量参数的传递

K 通过一个 uint32 数组传入（input_names 声明），内核体里 `K = kdim[0]`——标量也是数组，MLX 的统一 IO 哲学。

### 4.4 grid 语义回顾

`grid=(M*256,1,1)` 总线程数（22 的坑在此复发一次）——M 行 × 每行 256 线程。

## 5. 关键代码

```python
gemv_kernel = metal_kernel(name="my_gemv",
    input_names=["w", "x", "k_dim"], output_names=["y"],
    source="""
    uint gid = threadgroup_position_in_grid.x;   // 一组一行
    ...
    for (uint k = lid; k < K; k += lsize) acc += row[k] * x[k];
    ...
    if (lid == 0) { y[gid] = scratch[0]; }
    """)
```

## 6. 文件结构

```
23_gemv/
├── README.md              # 本文档
├── gemv.sh                # 主演示脚本
├── gemv.py                # 实验程序：GEMV 内核 + 对照验证
└── images/
    ├── gemv.dataflow.json # 图源
    ├── gemv.html          # 交互版
    └── gemv.svg           # 双主题矢量版
```

## 7. 深入要点

- **GEMV 为什么是带宽受限？** 每 2 FLOP 摊 4 字节（读 W 一行+x 一列），强度 0.5——优化重点是占满带宽。
- **组内跨步分摊的好处？** K 远大于组大小时均匀分摊负载，避免单线程长尾。
- **如何向 MPS/原生内核看齐？** simd shuffle 规约、多行并行、float4 化——教学版到生产版的路线图。

## 8. 总结

GEMV 到手。下一篇把两个算子缝进一个内核——融合 RMSNorm + QKV。

→ 下一篇：[24 · 融合 RMSNorm+QKV](../24_fused_rmsnorm_qkv/README.md)
