# 24 · 融合算子：RMSNorm + QKV 缝成一个内核

> LLM 解码每步都要 RMSNorm → Q/K/V 三次投影。分离执行要把中间激活
> 写回显存再读出三次；融合内核让数据"算完不落地"——
> 手写融合与 mx.compile（16）的本质区别：自己决定数据留在哪。

## 1. 为什么需要它

mx.compile 只能融合逐元素子图；跨"归约 + 矩阵乘"边界的融合必须手写。RMSNorm+QKV 是 LLM 推理最高频的融合对，也是手写融合的最佳教学样本。

## 2. 总览：核心机制一图看懂

![融合算子数据流](images/fused_rmsnorm_qkv.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/24_fused_rmsnorm_qkv/images/fused_rmsnorm_qkv.html)（或本地打开 [`images/fused_rmsnorm_qkv.html`](images/fused_rmsnorm_qkv.html)）。

x 与四组权重一次读入融合内核，与分离执行对答案。一句话心智模型：**归约一次 rms，然后 Q/K/V 三条投影并行奔流**。

## 3. 快速开始

```bash
./fused_rmsnorm_qkv.sh           # 一条龙
```

真实输出：

```
融合 vs 分离 最大绝对差: 9.54e-07
分离执行: 0.009 ms | 融合内核: 0.009 ms
✅ 验证通过：融合内核与分离执行数值一致
```

验证方法：融合输出与分离参照的最大绝对差 < 1e-6 量级——融合是搬运优化，不改数学。

## 4. 核心概念

### 4.1 两步结构

步骤1：全组协作归约出 rms(x)（又是 03 的骨架）。步骤2：每线程负责若干输出维度，norm 后的激活直接在寄存器里与三组权重做点积——**中间激活零次显存往返**。

### 4.2 权重约定的一致性（本实验的坑）

内核按 `(out, in)` 行主序取权重 `wq[d*512+c]`；MLX 侧参照写的是 `normed @ wq`（即 in×out）——**两种约定混用结果差 2.19**，对照时必炸。修正：参照统一用 `wq.T`。框架约定与自己内核的约定对齐，是手写融合的第一戒律。

### 4.3 单 token 的特殊性

解码期 batch=1：x 只有一行，一个线程组即可覆盖整行——归约与投影同组完成，无跨组通信。

### 4.4 性能解读

本实验规模下两者同为 0.009ms（启动开销主导）；规模放大后融合优势才显现——**融合的收益要从访存量算，不要从小规模计时猜**。

## 5. 关键代码

```metal
// 步骤1：组内归约 rms
for (uint st = lsize/2; st > 0; st >>= 1) { ... }
float rms = 1.0 / sqrt(s[0] / 512.0 + e);
// 步骤2：norm 与三投影一气呵成
q[d] = Σ_c nv(c) * wq[d*512+c];   // nv = x[c]*rms*wn[c]
```

## 6. 文件结构

```
24_fused_rmsnorm_qkv/
├── README.md                          # 本文档
├── fused_rmsnorm_qkv.sh               # 主演示脚本
├── fused_rmsnorm_qkv.py               # 实验程序：融合内核 + 分离对照
└── images/
    ├── fused_rmsnorm_qkv.dataflow.json # 图源
    ├── fused_rmsnorm_qkv.html          # 交互版
    └── fused_rmsnorm_qkv.svg           # 双主题矢量版
```

## 7. 深入要点

- **手写融合 vs mx.compile？** 手写可跨归约/矩阵乘边界、控制内存驻留；compile 安全便捷但限逐元素子图。
- **融合最容易错的地方？** 权重布局约定（out,in vs in,out）与归约的 barrier——两者错位都不报错只出错数。
- **为什么融合在 batch=1 时收益最大？** 访存占比最高（算力富余），省一次往返就是省大头。

## 8. 总结

手写融合毕业。下一篇上量化：INT4 权重的 GEMV。

→ 下一篇：[25 · INT4 量化 GEMV](../25_int4_gemv/README.md)
