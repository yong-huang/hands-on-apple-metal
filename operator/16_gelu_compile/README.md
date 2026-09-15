# 16 · GELU 与 mx.compile 融合

> 手写 GELU 由 5 个逐元素算子组成——每个都把 64MB 搬一遍显存。
> mx.compile 在编译期把它们缝成一个内核：一次读、一次写。
> 数值一位不变，速度肉眼可见。

## 1. 为什么需要它

融合是带宽受限算子（06：强度 0.5 ≪ 拐点 10）唯一正确的优化方向。mx.compile 让你"写清晰的链路，得融合的内核"——这是 MLX 相对传统框架最锋利的一把刀。

## 2. 总览：核心机制一图看懂

![GELU 融合数据流](images/gelu_compile.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/operator/16_gelu_compile/images/gelu_compile.html)（或本地打开 [`images/gelu_compile.html`](images/gelu_compile.html)）。

同一输入分别走手写 5 算子链与融合内核，数值与性能双验证。一句话心智模型：**5×64MB 的搬运压缩成 1×64MB**。

## 3. 快速开始

```bash
./gelu_compile.sh           # 一条龙
```

真实输出：

```
✅ 正确性：融合前后逐元素一致
手写链路: 1.84 ms/次
mx.compile 融合: 0.62 ms/次（加速 2.97×）
✅ 验证通过：数值不变，融合显著更快
```

验证方法：allclose(atol=1e-6) 逐元素比对——融合是搬运优化，不许改数学。

## 4. 核心概念

### 4.1 GELU 的两种形态

精确式 `x·Φ(x)` 用误差函数；工程标准用 tanh 近似（本实验）：`0.5x(1+tanh(√(2/π)(x+0.044715x³)))`——展开后 5 个逐元素算子。

### 4.2 mx.compile 的边界

只融合"逐元素为主"的子图；遇到 matmul 等大算子自动分段。它不改变数值语义（本实验 1e-6 内一致），这是与手写融合内核的本质区别——省心，但灵活度低一档（24 是手写版）。

### 4.3 计时的纪律

首轮包含编译，必须预热吸收；多轮取均值——22-30 的 benchmark 都沿用本实验的计时纪律。

## 5. 关键代码

```python
def gelu_manual(x):
    return 0.5 * x * (1 + mx.tanh(0.7978845608 * (x + 0.044715 * x**3)))
gelu_fused = mx.compile(gelu_manual)   # 一行触发融合
```

## 6. 文件结构

```
16_gelu_compile/
├── README.md                  # 本文档
├── gelu_compile.sh            # 主演示脚本
├── gelu_compile.py            # 实验程序：双实现 + 数值/性能双验证
└── images/
    ├── gelu_compile.dataflow.json # 图源
    ├── gelu_compile.html          # 交互版
    └── gelu_compile.svg           # 双主题矢量版
```

## 7. 深入要点

- **融合为什么能加速？** 带宽受限算子链：N 个算子 N 次往返 → 1 次；时间比即往返数比。
- **mx.compile 改数值吗？** 不改（逐元素语义保持）；但浮点累加顺序可能微调，用 allclose 而非 == 验证。
- **什么时候手写融合内核？** 需要跨"逐元素 + 归约/矩阵乘"边界或自定义内存模式时（见 20）。

## 8. 总结

融合利器到手。下一篇开始"对答案"：手写 RMSNorm 对齐 mx.fast 内置实现。

→ 下一篇：[17 · RMSNorm](../17_rmsnorm/README.md)
