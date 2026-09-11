# 18 · 数值稳定的 Softmax

> exp(1000) = inf——大数值输入会让朴素 softmax 当场产生 nan。
> log-sum-exp 技巧（先减最大值）在数学上完全等价，在数值上安然无恙。
> 本实验让两种实现当面对质。

## 1. 为什么需要它

attention logits 上千是常态而非极端案例。数值稳定性不是理论洁癖，是**每天都在发生的生产事故预防**。亲手触发一次溢出，比背十遍准则有效。

## 2. 总览：核心机制一图看懂

![Softmax 数据流](images/softmax.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/18_softmax/images/softmax.html)（或本地打开 [`images/softmax.html`](images/softmax.html)）。

大数值输入同时喂给朴素版（产 nan）与稳定版（正常输出），再与内置对照。一句话心智模型：**exp 单调，减常数不改分布，只改命运**。

## 3. 快速开始

```bash
./softmax.sh           # 一条龙
```

真实输出：

```
[正常输入] 朴素: [0.0900 0.2447 0.6652] | 稳定: [0.0900 0.2447 0.6652]
[大数值输入] 朴素: [nan nan nan] | 稳定: [0.0900 0.2447 0.6652]
[大数值] 内置 mx.softmax: [0.0900 0.2447 0.6652]
✅ 验证通过：log-sum-exp 技巧与内置实现一致，朴素版在大数值下产生 nan
```

验证方法：正常输入两版一致（等价性），大数值输入稳定版与 mx.softmax 逐元素一致（正确性），朴素版 nan（反例触发）。

## 4. 核心概念

### 4.1 log-sum-exp 技巧

`softmax(x) = exp(x − max(x)) / Σ exp(x − max(x))`。减 max 后 exp 参数 ≤ 0，结果 ∈ (0,1]——永不溢出。数学上 max 是常数可提出来消掉，完全等价。

### 4.2 nan 从哪来

exp(1002) = inf；inf/inf = nan。上溢一旦发生，nan 会沿着计算图污染所有下游。

### 4.3 反例的价值

让"必错"的版本真实跑一次并留下 nan 输出——错误模式的肌肉记忆，比代码评审更可靠。

### 4.4 同族问题

attention 的 scale（1/√d）本质也是同款防饱和：logits 方差随 d 增大，不缩放会让 softmax 提前饱和。

## 5. 关键代码

```python
def softmax_stable(x):
    m = mx.max(x, axis=-1, keepdims=True)
    e = mx.exp(x - m)
    return e / mx.sum(e, axis=-1, keepdims=True)
```

## 6. 文件结构

```
18_softmax/
├── README.md               # 本文档
├── softmax.sh              # 主演示脚本
├── softmax.py              # 实验程序：双实现对质 + 内置对照
└── images/
    ├── softmax.dataflow.json # 图源
    ├── softmax.html          # 交互版
    └── softmax.svg           # 双主题矢量版
```

## 7. 深入要点

- **为什么减 max 不改变结果？** exp 单调：分子分母同乘 exp(−m) 消掉——数学恒等，数值安全。
- **还有哪些算子需要同款处理？** log-sum-exp（交叉熵）、注意力权重、任何 exp/sigmoid 前的大值路径。
- **fp16 场景要更小心什么？** 上溢阈值降到 65504，减 max 从"可选优化"变成"生死攸关"。

## 8. 总结

数值稳定性入列。下一篇横向对比三个激活函数——LLM 的"非线性口味"。

→ 下一篇：[19 · 激活函数对比](../19_activations/README.md)
