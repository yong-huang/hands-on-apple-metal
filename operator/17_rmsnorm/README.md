# 17 · RMSNorm：手写 vs mx.fast 对答案

> RMSNorm 是 LLM 的标准归一化层。自己写一个，然后和
> mx.fast.rms_norm（苹果的手调内核）逐元素对答案——
> 差 9.5e-07，这就是"对答案式算子开发"的标准示范。

## 1. 为什么需要它

自研算子的第一课不是性能而是**正确性锚点**：有黄金参照时，每一步修改都能立即判对错。RMSNorm 足够简单（一行公式）又足够真实（LLM 每层都在用），是练习的最佳对象。

## 2. 总览：核心机制一图看懂

![RMSNorm 数据流](images/rmsnorm.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/17_rmsnorm/images/rmsnorm.html)（或本地打开 [`images/rmsnorm.html`](images/rmsnorm.html)）。

同一输入喂给手写实现与内置 fast 内核，最大绝对差判定。一句话心智模型：**x ÷ rms(x) × w，eps 加在均值上**。

## 3. 快速开始

```bash
./rmsnorm.sh           # 一条龙
```

真实输出：

```
手写 vs mx.fast 最大绝对差: 9.54e-07
归一化后各行 RMS ≈ 1.0002（期望 ≈ 1）
✅ 验证通过：手写 RMSNorm 与内置 fast 内核数值一致
```

验证方法：双验证——与内置实现的最大绝对差 < 1e-5，且输出除以 weight 后各行 RMS ≈ 1（结构性自检）。

## 4. 核心概念

### 4.1 公式与形状

`x / sqrt(mean(x², axis=-1) + eps) * w`：沿最后一维归一化，w 逐通道缩放。形状 [B, S, D] 的 D 维整体参与统计。

### 4.2 eps 的位置

eps 加进均值（`mean + eps` 再开方）——放在开方之后语义就错了。这是 RMSNorm 实现最常见分歧点，对答案能立刻暴露。

### 4.3 keepdims 的陷阱

`mx.mean(x*x, axis=-1)` 忘 keepdims 会得到 [B,S]，广播时语义静默错位——形状"看起来能算"但结果错。对答案直接揪出。

### 4.4 为什么是 RMSNorm 不是 LayerNorm

去均值化：只除 RMS 不减均值，省一次 pass——推理期无统计差异且更快，LLaMA 系全面采用。

## 5. 关键代码

```python
def rms_norm_manual(x, weight, eps=1e-5):
    ms = mx.mean(x * x, axis=-1, keepdims=True)
    return x / mx.sqrt(ms + eps) * weight
ref = mx.fast.rms_norm(x, w, 1e-5)     # eps 是位置参数
```

## 6. 文件结构

```
17_rmsnorm/
├── README.md              # 本文档
├── rmsnorm.sh             # 主演示脚本
├── rmsnorm.py             # 实验程序：手写 + 对照 + 双验证
└── images/
    ├── rmsnorm.dataflow.json # 图源
    ├── rmsnorm.html          # 交互版
    └── rmsnorm.svg           # 双主题矢量版
```

## 7. 面试要点

- **RMSNorm vs LayerNorm？** 去掉均值中心化：少一次归约、无偏移参数；效果在大模型上相当。
- **eps 为什么必须加在方差上？** 防止除零且保持量纲；加错位置在小输入时误差爆炸。
- **对答案的黄金参照从哪来？** 框架 fast 内置实现 / 参考论文公式 / numpy 逐步——三方一致才算锚定。

## 8. 总结

对答案流程成型。下一篇制造一个"必错"的对照：让朴素 softmax 当众溢出。

→ 下一篇：[18 · 数值稳定 Softmax](../18_softmax/README.md)
