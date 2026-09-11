# 19 · 激活函数对比：ReLU / SiLU / GELU

> ReLU 一刀切零；SiLU 带一点负弯；GELU 更平滑——
> 三种激活塑造了三代模型的"非线性口味"。
> 本实验并排画出曲线、给出性能数字，并验证形状的结构性质。

## 1. 为什么需要它

激活函数是网络里唯一的非线性来源。理解三者的形状差异（尤其负半轴），才能读懂"为什么 LLaMA 用 SwiGLU、GPT 用 GELU"这类选型讨论。

## 2. 总览：核心机制一图看懂

![激活函数数据流](images/activations.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/19_activations/images/activations.html)（或本地打开 [`images/activations.html`](images/activations.html)）。

同一输入施加三种激活，曲线对比 + 4096² 大规模计时。一句话心智模型：**ReLU 是开关，SiLU/GELU 是带负半轴"小水沟"的软开关**。

## 3. 快速开始

```bash
./activations.sh           # 一条龙
```

真实输出：

```
x      : [-4.0, -3.0, -2.0, -1.0, 0.0, 1.0, 2.0, 3.0, 4.0]
ReLU   : [0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 2.0, 3.0, 4.0]
SiLU   : [-0.07, -0.04, -0.24, -0.27, 0.0, 0.73, 1.76, 2.86, 3.99]
GELU   : [0.0, 0.0, -0.05, -0.16, 0.0, 0.84, 1.95, 2.996, 3.99]
负半轴差异: ReLU 硬归零，SiLU 保留微弱负值（-0.067）——这是 SwiGLU 优于 ReLU 的解释之一
4096² 前向耗时: ReLU 0.31 ms | SiLU 0.62 ms | GELU 0.71 ms
✅ 验证通过：三种激活的形状与性能符合预期
```

验证方法：结构断言——ReLU 负半轴严格为 0；SiLU 负值 ∈ (−1, 0)；正半轴三者趋同于 x。

## 4. 核心概念

### 4.1 公式

ReLU = max(x, 0)；SiLU = x·σ(x)（LLaMA 系）；GELU = x·Φ(x) ≈ 0.5x(1+tanh(…))（GPT 系）。

### 4.2 形状即行为

负半轴的"小水沟"保留了微弱负信息，梯度不因一刀切而死亡——这是 SiLU/GELU 在深层网络中梯度流更好的直观解释。

### 4.3 性能视角

三者都是逐元素/带宽受限（06 视角）：耗时差来自算子复杂度（SiLU 需 sigmoid、GELU 需 tanh+多项式），但都远小于结构差异带来的模型质量影响。

### 4.4 mx.nn 与手写

`mx.nn.silu/gelu` 是 fast 路径；手写公式（本实验验证用）应与 fast 数值一致——又是"对答案"。

## 5. 关键代码

```python
silu = x * mx.sigmoid(x)
gelu = 0.5 * x * (1 + mx.tanh(0.7978845608 * (x + 0.044715 * x**3)))
assert float(relu[3]) == 0.0 and -1 < float(silu[3]) < 0   # 结构断言
```

## 6. 文件结构

```
19_activations/
├── README.md                  # 本文档
├── activations.sh             # 主演示脚本
├── activations.py             # 实验程序：曲线 + 计时 + 结构断言
└── images/
    ├── activations.dataflow.json # 图源
    ├── activations.html          # 交互版
    └── activations.svg           # 双主题矢量版
```

## 7. 面试要点

- **SiLU/GELU 优于 ReLU 的直观解释？** 负半轴非零保留梯度与信息；平滑性改善优化景观。
- **GELU 的 tanh 近似误差多大？** 全域 <1e-3，工程标准形；精确式用 erf 但多一次特殊函数开销。
- **激活函数是带宽受限吗？** 是（逐元素），所以选型看模型质量而非算子耗时。

## 8. 总结

非线性三兄弟登场完毕。下一篇是大 boss：手写 Attention 并与融合内核对答案。

→ 下一篇：[20 · Attention 算子](../20_attention/README.md)
