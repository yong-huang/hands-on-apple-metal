# 28 · 轻量推理引擎算子层

> MatMul、Add、ReLU、Softmax、LayerNorm——五个算子，
> 一个注册表，一张七节点的计算图，跑出一个完整的 MLP 前向。
> 100 行代码看清推理引擎的骨架。

## 1. 为什么需要它

会用算子之后要会"组织"算子：统一协议、注册表、图编排——推理引擎（ONNX Runtime、MLC、llama.cpp）的全部结构秘密，在 CPU 上的最小标本里就能看全。

## 2. 总览：核心机制一图看懂

![推理引擎数据流](images/mini_engine.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/operator/28_mini_engine/images/mini_engine.html)（或本地打开 [`images/mini_engine.html`](images/mini_engine.html)）。

五个算子注册进表，链式图顺序执行输出概率分布。一句话心智模型：**引擎 = 算子协议 + 注册表 + 编排器**。

## 3. 快速开始

```bash
./mini_engine.sh           # 一条龙
```

真实输出：

```
已注册算子: MatMul, Add, ReLU, Softmax, LayerNorm（注册表映射到首个实例）
MLP 前向: [1,64] → LayerNorm → 128 → ReLU → 10 → Softmax
输出概率: 0.081 0.095 0.118 0.088 0.121 0.079 0.107 0.114 0.092 0.105
概率和 = 1.000000（期望 = 1）
✅ 引擎验证通过：5 算子编排执行，输出为合法概率分布
```

验证方法：结构断言——Softmax 后概率非负且和为 1（无需参照值的正确性证明）。

## 4. 核心概念

### 4.1 算子协议

```swift
protocol Operator { var name: String; func forward([Tensor]) -> Tensor }
```

所有算子长一个样——引擎的循环不关心具体算子。这是"框架化"的全部秘密。

### 4.2 注册表

`registry["MatMul"] = MatMul(...)`：按名索引。新增算子 = 注册一个类型，引擎代码零改动。权重作为构造参数闭进算子实例——引擎与权重解耦。

### 4.3 链式图编排

`g.add(norm); g.add(matmul1)...` 顺序即数据流：上一层输出即下一层输入。真实的 DAG 引擎在此之上加多输入拓扑排序——骨架不变。

### 4.4 结构验证

Softmax 输出非负、和为 1：不需要参照值就能断言的**结构性质**——复杂系统的验证要善用这类不变量。

## 5. 关键代码

```swift
func run(_ input: Tensor) -> Tensor {
    var stack: [Tensor] = [input]
    for (op, _) in nodes {
        let arg = stack.removeLast()
        stack.append(op.forward([arg]))
    }
    return stack[0]
}
```

## 6. 文件结构

```
28_mini_engine/
├── README.md                  # 本文档
├── mini_engine.sh             # 主演示脚本
├── main.swift                 # 入口包装
├── mini_engine.swift          # 实验程序：协议 + 注册表 + 图执行
└── images/
    ├── mini_engine.dataflow.json # 图源
    ├── mini_engine.html          # 交互版
    └── mini_engine.svg           # 双主题矢量版
```

## 7. 深入要点

- **推理引擎的核心抽象？** 算子接口（形状推断 + 计算）、图 IR、内存规划、调度——本实验覆盖前两个。
- **为什么权重闭进算子而不是图输入？** 权重编译期已知可预绑定；激活才是运行时数据流——两者的生命周期不同。
- **从本标本到 ONNX Runtime 还差什么？** 形状推断、DAG 拓扑排序、内存池复用、多后端分发、量化内核。

## 8. 总结

引擎骨架立住。倒数第二站：给 MPS 流水线写一个它没有的滤镜。

→ 下一篇：[29 · 自定义滤镜](../29_custom_filter/README.md)
