# 22 · MLX 自定义 Metal 内核

> 在 Python 里内嵌一段 MSL（Metal Shading Language，写 Apple GPU 内核用的语言）源码，MLX 负责生成函数签名——mx.fast.metal_kernel 是 Python 算子开发的官方通道。读完你能写出第一个向量加法内核，并当场踩掉两个语义坑：grid 是总线程数、边界覆盖是算子自己的责任。

## Background

想在模型里加一个 MLX 内置算子（operator，执行单一数学运算的基本计算单元，如矩阵乘、向量加法）没有的 GPU 计算（自定义量化格式、少见的融合组合），传统路子是：

建 Xcode（Apple 的官方开发环境）工程、写完整的 Metal（Apple 的 GPU 计算框架）内核源文件、配置编译，再在宿主语言里手动绑定显存缓冲，最后桥接回 Python。

为了十行 GPU 代码维护整套脚手架，得不偿失；退回 CPU 用 NumPy 算，则丢掉 GPU 的并行性能。

内核（kernel，GPU 上运行的函数，由大量线程（GPU 执行的最小工作单位）并行执行同一份代码）开发的样板成本，是这条路最大的门槛。

MLX 的 mx.fast.metal_kernel 应运而生：Python 里直接内嵌 MSL 源码，函数签名、编译、显存绑定全部由框架代劳，不需要 Xcode 工程、不需要编译配置。

## What

mx.fast.metal_kernel 是 MLX 提供的"在 Python 里定义并调用自定义 Metal 内核"的接口：传入输入输出名字与一段 MSL 函数体，返回一个可像函数一样调用的内核对象。

一句话心智模型：**声明 IO 名字，只写函数体**。可以把 MLX 想象成一个自动写"函数头"的助手：你只填函数体，参数表与类型声明由它按你传入的数组现场生成。失效边界：托管覆盖的是常规情形，需要精细控制内存布局、特殊参数属性等高级特性时，控制粒度不及原生 Metal 工具链。

还有一个必须建立的概念：边界覆盖。GPU 内核的线程数由调用方声明，线程不够时哪些元素没被写入、写了会怎样，是算子自己的责任——本实验用一个反例演示。

## When to Use

典型场景：

- **内置算子覆盖不到的自定义数值逻辑**：自定义量化格式（把权重压成低精度整数以省显存）的反量化、把几个运算合并成一个内核的融合（fusion，减少中间结果读写）等。
- **原型验证**：在 Python 循环里直接试一段 MSL 片段，不必搭 Xcode 工程。
- **学习 GPU 编程模型**：grid、threadgroup 的语义可以用最小实验当场看清。

何时不用：

- 内置算子或 mx.fast 已有对应实现：直接用框架内核，它们经过调优。
- 需要深度控制硬件细节且托管接口不够用：回到原生 Metal 工程工具链。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| mx.fast.metal_kernel | Python 内嵌 MSL，签名/编译托管 | 快速自定义算子与原型 |
| MLX 内置 / mx.fast 算子 | 框架预置、经过调优 | 有现成实现时一律优先 |
| 原生 Metal + Xcode 工程 | 完整控制，样板代码多 | 复杂计算管线、深度调优 |
| CUDA（NVIDIA 平台的同类编程模型） | 同类抽象，另一硬件生态 | 在 NVIDIA GPU 上做同样的事 |

## Quick Start

前置条件：macOS 与 Apple Silicon 设备，装有 MLX（Apple 为 Apple Silicon 出品的机器学习框架）。片段式 source 写法自 MLX 0.32 起生效。

```bash
./custom_kernel.sh           # 一条龙
```

真实输出：

```
out[:5] = [0.0, 3.0, 6.0, 9.0, 12.0]
✅ 验证通过：自定义内核 out = a + b 与期望一致
线程只派一半时后半区未写（示例 0, 0）——这就是边界检查的意义
✅ 自定义内核入门完成：声明式 IO + MSL 源码 + 显式网格
```

验证方法：out 与 arange×3 逐元素相等；反例（线程只派一半）输出后半区保持初始值——覆盖不足的错误模式亲眼见过。

关键代码（这段在做什么：`input_names`/`output_names` 声明输入输出，`source` 只写函数体，每个线程把自己那一格算成 a+b；调用时 `grid` 给出总线程数，`threadgroup` 给出每组线程数）：

```python
add_kernel = metal_kernel(name="my_vector_add",
    input_names=["a", "b"], output_names=["out"],
    source="uint i = thread_position_in_grid.x; out[i] = a[i] + b[i];")
(out,) = add_kernel(inputs=[a, b], output_shapes=[(n,)], output_dtypes=[mx.float32],
                    grid=(n, 1, 1), threadgroup=(256, 1, 1))
```

## How It Works

**片段式源码。** MLX 0.32 起，source 只写函数体：`uint i = thread_position_in_grid.x; out[i] = a[i] + b[i];`。

内核签名（函数的参数表）、buffer（显存中的数组区域）绑定、dtype（数据类型）模板全部由 MLX 按输入数组自动生成；老式整段 kernel 写法反而编译失败。这样设计的原因：IO 名字与传入的数组一一对应，框架据此生成签名与绑定，把样板成本降到零。

**grid = 总线程数（最大的坑）。** `grid=(n,1,1)` 是线程总数，不是线程组数——`threadgroup_position_in_grid` 的范围是 0…n/threadgroup−1。

threadgroup（线程组，一批编成小组的线程）是 GPU 上资源分配与同步的单位，这里 (256,1,1) 表示每组 256 个线程。按 CUDA（NVIDIA 平台的编程模型）习惯把 grid 当"组数"传，实际派发的线程会静默少算——lab 23 与 lab 25 实测踩过。

**边界覆盖是算子的责任。** 线程不足时，输出数组没被写到的区域保持旧数据，且不报错。输出第 3 行的反例正是这一模式：线程只派一半，后半区仍是初始值（示例 0, 0）。两个防御方向：要么 grid 覆盖全部元素，要么在内核里做边界检查。

## Pitfalls & Q&A

**坑：把 grid 当线程组数。** 现象：输出只有一部分被更新（常见恰好一半），其余保持初始值，且不报任何错。原因：MLX 的 grid 语义是总线程数，按 CUDA 的"组数"习惯传参，派发线程数少了 threadgroup 倍。

解法：记住 grid = 总线程数；断言 grid 覆盖全部元素，或在内核尾部做边界检查——把这条检查做成算子的单元测试。

**Q：MLX metal_kernel 与原生 Metal 的关系？** 底层同样是 MSL + Metal，但签名、编译、绑定由 MLX 托管——用开发效率换部分控制粒度。

**Q：grid 语义为什么这样定？** MLX 选择"总线程数"抽象，以匹配 Metal 的 dispatchThreads（按线程总数派发的接口）调用；使用者的心智模型要从"组数"切换过来。
