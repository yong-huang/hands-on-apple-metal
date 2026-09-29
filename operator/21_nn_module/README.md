# 21 · 自定义 nn.Module：Linear 的最小复刻

> 用 40 行手写一个 MyLinear，复刻框架 nn.Linear（线性层，计算 y = x·W + b）的参数注册、前向计算与 safetensors 存取三件事。读完你能看懂 MLX 模型底座怎么运作：参数怎么收集、状态怎么保存、加载怎么还原。

## Background

没有 Module 这类抽象时，参数要靠手工管理：自己维护权重字典、自己写保存与加载函数。把一个十几层的网络存到磁盘再还原，每层各写各的代码，字段名对不上、漏存一层就会报错；训练循环也没法统一遍历所有参数去更新。

PyTorch 的 nn.Module（网络层的基类约定）解决了这件事：把"收集参数"和"组织前向计算"做成统一的父类模板，子类只管定义自己的层。MLX 的 nn.Module 沿用同一思路，且注册方式更隐式。

读懂 MLX 的 Module 机制等于读懂整个 MLX 模型生态：参数怎么注册、状态怎么保存、加载怎么还原。40 行的 MyLinear 是最小完备样本，参数注册、前向、存取三件齐备。

## What

nn.Module 是框架里所有网络层的基类（父类模板），负责两件事：收集参数（可训练的数值，如权重矩阵 W、偏置向量 b）与定义前向（forward，从输入算到输出的一遍计算）。本实验的 MyLinear 是它最小化的复刻。

一句话心智模型：**Module = 参数字典 + 前向函数**。可以把 Module 想象成自带清单的工具箱：放进去的可训练数组自动登记造册（进 `parameters()` 字典），前向函数决定这些工具怎么组合使用。

失效边界：登记只覆盖赋值为 `mx.array`（MLX 的多维数组类型）的属性，普通 Python 数字与容器不会进清单。

MyLinear 对应框架 nn.Linear：输入 x，输出 x @ W.T + b。权重的初始化范围是 ±1/√in 的均匀分布，细节在 How It Works 展开。

## When to Use

典型场景：

- **给模型添加自定义层**：框架没有的结构，写一个 nn.Module 子类，即可被 `parameters()` 收集、参与训练与存取。
- **实现或调试操作权重的工具**：LoRA（只训练少量附加参数的微调方法）、量化（把权重压成低精度整数以省显存）这类工具，本质都在遍历或替换 Module 的参数字典。
- **阅读开源 MLX 模型代码**：所有层都继承 nn.Module，看懂一个就看懂全部。

何时不用：

- 只使用现成模型、不做改动：直接加载即可，不必自己写层。
- 一次性计算脚本：裸函数加几个数组更短，套 Module 是额外结构开销。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| MLX nn.Module 自定义层 | 属性赋值即自动注册 | 在 MLX 生态写模型 |
| PyTorch nn.Module | 需 nn.Parameter 显式包装 | 在 PyTorch 生态写模型 |
| mx.nn.Linear 等内置层 | 框架现成、经过验证 | 标准结构直接用 |
| 裸函数 + 手工字典 | 无自动收集与统一存取 | 一次性脚本 |

## Quick Start

前置条件：macOS 与 Python 环境，装有 MLX（Apple 为 Apple Silicon 出品的机器学习框架，下文以 `mx` 指代其核心模块）。

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

完整实现（这段在做什么：`__init__` 里给 weight、bias 赋值 `mx.array`，赋值即完成参数注册；`__call__` 定义前向计算；`scale` 把随机初始化约束在 ±1/√in 内）：

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

## How It Works

三件套逐个拆开，每件对应输出里的一行验证。

**参数注册：赋值即收集。** 赋值为 `mx.array` 的属性自动进入 `parameters()` 字典——注册是隐式而自动的，这是 MLX Module 的设计巧思。

对比 PyTorch：需要用 nn.Parameter 或 register_parameter 显式包装。输出第 1 行"参数清单"打印的就是这个字典：weight [32,64]、bias [32]。

**前向 = `__call__`。** `MyLinear(64,32)(x)` 调用的是 `__call__` 方法——保持与 nn.Linear 相同的使用接口。输出第 2 行验证了前向与手算 `x @ W.T + b` 一致。

**初始化为什么是 ±1/√in。** 均匀分布（在区间内等概率取值）范围取 ±1/√in，能让输出的方差与前一层处于同一量级——层数堆深时信号既不放大也不消失。这是 Xavier 家族（让各层输出方差保持稳定的权重初始化方法家族）的简化版。

**safetensors 存取。** `layer.save_weights(path)` 与 `load_weights(path)` 负责落盘与还原。safetensors 是"安全（不执行代码）+ 零拷贝（内存映射，不复制数据直接读）"的权重文件格式，是 HuggingFace（模型开源生态社区）的通用格式。

输出第 3 行"逐位一致"验证了存取无损。

## Pitfalls & Q&A

**坑：临时缓存混进参数清单。** 现象：`parameters()` 里出现不打算训练的数组，或保存文件比预期大。原因：MLX 的注册是隐式的，所有赋值为 `mx.array` 的属性都会被收集，MLX 不区分"参数"与"缓存"。解法：不参与训练/保存的数据改用普通 Python 容器存放。

**Q：safetensors 相比 pickle 的优势？** pickle（Python 自带的序列化机制，把内存中的对象转成可存储的字节）加载时会执行文件内的任意代码，存在安全风险；safetensors 只存数值、不执行代码，且支持零拷贝内存映射、跨框架通用。

**Q：为什么 weight 形状是 (out, in)？** 前向是 `x @ W.T`——与 PyTorch 的 Linear 一致。转置后输入通道连续存放，矩阵乘读取时内存访问连续，缓存友好。

**Q：保存/加载后报错或输出不一致？** 权重文件与目标层的参数树（名字与形状）对不上。解法：先用相同结构实例化，再用 `parameters()` 核对参数清单，然后 load_weights。
