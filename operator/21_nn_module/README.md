# 21 · 自定义 nn.Module：Linear 的最小复刻

> 框架的 nn.Linear 是黑盒？自己写一个 40 行的 MyLinear：
> 参数注册、前向计算、safetensors 存取——三件套齐活。
> 这就是 LoRA/量化工具操作模型权重的同一套底座。

## 1. 为什么需要它

读懂 nn.Module 的机制 = 读懂整个 MLX 模型生态：参数怎么注册、状态怎么保存、加载怎么还原。40 行的 MyLinear 是最小完备样本。

## 2. 总览：核心机制一图看懂

![nn.Module 数据流](images/nn_module.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/21_nn_module/images/nn_module.html)（或本地打开 [`images/nn_module.html`](images/nn_module.html)）。

定义 → 前向验证 → safetensors 落盘重建。一句话心智模型：**Module = 参数字典 + 前向函数**。

## 3. 快速开始

```bash
./nn_module.sh           # 一条龙
```

真实输出：

```
参数清单: {'weight': [32, 64], 'bias': [32]}
✅ 前向验证: 输出 [8,32]，与手算一致
✅ 保存/加载验证: 重建的层前向输出逐位一致
```

验证方法：前向与 `x @ W.T + b` 手算一致；保存后重建新实例加载权重，输出逐位相同。

## 4. 核心概念

### 4.1 参数注册

赋值为 `mx.array` 的属性自动进入 `parameters()` 字典——注册是隐式而自动的，这是 MLX Module 的设计巧思。

### 4.2 前向 = `__call__`

`MyLinear(64,32)(x)` 调用的是 `__call__`——保持与 nn.Linear 相同的使用接口。

### 4.3 safetensors 存取

`layer.save_weights(path)` / `load_weights(path)`：safetensors 是安全（无代码执行）+ 零拷贝的权重格式，HuggingFace 生态通用。

### 4.4 初始化

`±1/√in` 的均匀分布——保持前向方差稳定的标准做法（Xavier 家族的简化版）。

## 5. 关键代码

```python
class MyLinear(nn.Module):
    def __init__(self, in_features, out_features):
        super().__init__()
        scale = 1.0 / in_features**0.5
        self.weight = mx.random.uniform(-scale, scale, (out_features, in_features))
        self.bias = mx.zeros((out_features,))
    def __call__(self, x):
        return x @ self.weight.T + self.bias
```

## 6. 文件结构

```
21_nn_module/
├── README.md                # 本文档
├── nn_module.sh             # 主演示脚本
├── nn_module.py             # 实验程序：自定义层 + 存取验证
└── images/
    ├── nn_module.dataflow.json # 图源
    ├── nn_module.html          # 交互版
    └── nn_module.svg           # 双主题矢量版
```

## 7. 面试要点

- **MLX Module 的参数注册机制？** 属性赋值 mx.array 即自动收集——相比 PyTorch 的 register_parameter 更隐式。
- **safetensors 相比 pickle 的优势？** 不执行任意代码（安全）、支持零拷贝内存映射、跨框架通用。
- **为什么 weight 形状是 (out, in)？** 前向 x @ W.T——与 PyTorch Linear 一致，缓存友好（输入通道连续）。

## 8. 总结

框架底座摸透。从这里开始进入真正的深水区：在 MLX 里写自己的 Metal 内核。

→ 下一篇：[22 · 自定义 Metal 内核](../22_custom_kernel/README.md)
