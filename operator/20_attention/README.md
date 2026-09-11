# 20 · Attention：手写 vs mx.fast

> Attention 是 Transformer 的算子心脏。手写 QKᵀ/√d → softmax → ·V
> 三步链路，与 mx.fast.scaled_dot_product_attention 逐元素对答案——
> 最大差 3.3e-04，这正好是一堂"如何设定容差"的实践课。

## 1. 为什么需要它

会手写 attention 是读懂一切 transformer 实现的门票；知道融合内核与自己写的**差多少、为什么差**，则是算子工程师的分水岭。

## 2. 总览：核心机制一图看懂

![Attention 数据流](images/attention.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/20_attention/images/attention.html)（或本地打开 [`images/attention.html`](images/attention.html)）。

Q/K/V 三输入分别喂给手写三步链路与融合内核，双向对答案。一句话心智模型：**softmax(QKᵀ/√d)·V——加权求和，权重由相似度决定**。

## 3. 快速开始

```bash
./attention.sh           # 一条龙
```

真实输出：

```
形状: (2, 4, 256, 64) → 输出 (2, 4, 256, 64)
手写 vs mx.fast 最大绝对差: 3.26e-04
注意力权重行和 ≈ 1.000000（期望 = 1）
✅ 验证通过：手写 SDP 与 mx.fast 融合内核数值一致
```

验证方法：双验证——与融合内核的最大绝对差 < 1e-3（浮点累加顺序差），注意力权重行和 = 1（结构不变量）。

## 4. 核心概念

### 4.1 三步分解

logits = (Q/√d)Kᵀ [B,H,S,S] → 稳定 softmax → 加权 V。转置 `k.transpose(0,1,3,2)` 是最易写错的一步。

### 4.2 容差设定是素养

3.3e-04 不是误差，是**浮点累加顺序不同**的必然：融合内核的分块归约与手写链路的逐元素顺序不同。阈值 1e-4 会误报，1e-3 才合理——"知道自己的容差"是算子工程师的素养。

### 4.3 结构不变量

softmax 行和恒为 1——不需要参照值即可验证的结构性质。与数值对答案互补：一个查正确性、一个查语义。

### 4.4 scale 的意义

1/√d 抑制 logits 方差随维度增长（否则 softmax 提前饱和）——18 的数值稳定性在 attention 里的正牌应用。

## 5. 关键代码

```python
def attention_manual(q, k, v, scale):
    logits = (q * scale) @ k.transpose(0, 1, 3, 2)
    m = mx.max(logits, axis=-1, keepdims=True)
    p = mx.softmax(logits - m, axis=-1)     # 复用 18 的稳定技巧
    return p @ v
ref = mx.fast.scaled_dot_product_attention(q, k, v, scale=1.0 / D**0.5)
```

## 6. 文件结构

```
20_attention/
├── README.md                 # 本文档
├── attention.sh              # 主演示脚本
├── attention.py              # 实验程序：手写 SDPA + 融合对照 + 双验证
└── images/
    ├── attention.dataflow.json # 图源
    ├── attention.html          # 交互版
    └── attention.svg           # 双主题矢量版
```

## 7. 深入要点

- **为什么除以 √d？** 点积方差 ∝ d，不缩放则 softmax 梯度消失（饱和）。
- **融合 SDPA 快在哪？** 不物化 S×S 的注意力矩阵（flash attention 思想），显存与带宽双省。
- **手写版的价值？** 教学透明 + 定制自由（mask/偏置/稀疏模式）；生产用融合内核。

## 8. 总结

Transformer 心脏解剖完成。下一篇回到框架层：亲手复刻 nn.Module 的三件套。

→ 下一篇：[21 · 自定义 nn.Module](../21_nn_module/README.md)
