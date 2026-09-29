# 27 · Metal 4 · MTLTensor

> MTLTensor 是 Metal 4 新增的 GPU 资源：一段自带形状（shape）语义的内存，让机器学习数据在 Metal 里有原生表达。读完本篇你能亲手创建张量、读懂 shape / rank / stride / usage 这些属性，并了解当前真机实测的能力边界（本实验在 macOS 26.5 上如实记录）。

## Background

机器学习的数据天生是 N 维的：一张 RGB 图片是 3 维数组（高 × 宽 × 通道），一个批次是 4 维。而 Metal 原有的 MTLBuffer（Metal 里一段指定长度的连续内存）只知道"我有多长"，不知道内容是几维、每维多长。

没有张量类型时，人们只能在 buffer 上硬造维度语义：靠约定办事——"前 4 字节存行数"、"按行主序（一行元素在内存里排完再排下一行的排布约定）手工计算偏移"。

维度信息活在文档和开发者的脑子里，着色器拿到的只是一根裸指针。一旦要做 reshape（改变维度划分而不搬动数据）或切片，就得手算内存偏移，算错就是越界或读错数据；不同框架的布局约定还可能不一致，数据在管线之间传递时要反复对齐约定。

Metal 4（Apple 2025 年发布的新一代 Metal）把张量升格为一等资源：维度、元素类型、用途都是资源自身的属性，由驱动按硬件布局要求分配。AI 管线的数据流从此有了原生表达，不必再靠口头约定。

## What

MTLTensor 是一种自带维度信息的 GPU 内存资源：创建时声明形状（shape，各维度的长度）与元素类型，之后张量自己"知道"自己是 [4,8,6] 还是 [192]。

连同 shape，相关的三个术语是：rank 是维度个数；stride 是相邻元素在内存中的字节间隔——shape 管"逻辑上怎么分维"，stride 管"物理上怎么排布"。

一句话心智模型：**MTLTensor = 知道自己形状的内存**。可以把 MTLBuffer 想象成一整条没有任何标记的长货架，把 MTLTensor 想象成贴了维度标签的立体货柜——取"第 2 层第 3 格"是货柜自己的能力。

但和多维数组不同的是，张量的物理布局还受硬件对齐约束（见 How It Works 的 stride 对齐），并不总是紧凑排列。

与直接用 buffer 的对照：

| 维度 | MTLBuffer | MTLTensor |
|---|---|---|
| 自带信息 | 只有字节长度 | shape、rank、dataType、usage |
| reshape/切片 | 手算偏移，易错 | 元数据层面的维度操作 |
| ML 布局要求 | 自己保证 | 创建时由驱动按 usage 处理 |

## When to Use

- 写机器学习计算内核时：Shader ML（Metal 4 在着色器语言层面新增的机器学习能力）以张量为原生数据面。
- 用 ML Command Encoder（Metal 4 的机器学习命令编码器）跑推理（inference：用训练好的模型对输入算出输出）时：张量是它消费的输入输出类型。
- GPU 通用计算里需要多维数据、且经常 reshape 或切片时：维度操作留在元数据层，不碰内存。

何时不用：

- 一维数据、传统图形管线的顶点/索引数据：MTLBuffer 更简单直接。
- 需要 CPU 频繁直接读写的小块数据：用共享存储（shared）的 MTLBuffer，CPU 可直接访问。
- 目标系统较旧时：MTLTensor 随 Metal 4 提供，只有较新的系统可用（本实验在 macOS 26.5 实测可用）。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| MTLBuffer | 只有长度的一维内存，布局全靠约定 | 一维数据、传统管线、CPU 直读 |
| MTLTensor（本文） | 自带 shape/dataType/usage 与 ML 对齐 | Shader ML、ML 编码器的数据面 |
| MPS（Metal Performance Shaders） | Apple 的现成高性能算子（operator，一个具体的计算单元，如矩阵乘、卷积）库，内部自行管理布局 | 直接调用成熟算子，不自己写内核 |
| MLX | Apple 更上层的机器学习数组框架 | 训练与原型研究，不碰 Metal 细节 |

## Quick Start

前置条件：macOS + Xcode，且系统支持 Metal 4。进入本目录运行：

```bash
./mtl_tensor.sh               # 一条龙
```

真实输出：

```
✅ MTLTensor 创建成功
  shape     = [4, 8, 6]（rank 3）
  dataType  = Float32（4 字节/元素）
  元素总数  = 192（768 字节）
  buffer    = nil（private 分配）
✅ MTLTensor 探索完成（Metal 4 张量可用）
```

验证方法：本实验的验收标准是"创建张量并打印维度属性"——shape/rank/dataType 全部打印即达成。输出里 `buffer = nil` 不是失败，而是当前实测的能力边界之一（原因见 How It Works）。

## How It Works

创建张量的完整流程是：填写描述符（descriptor，创建资源前提交的参数清单）三要素——dimensions、dataType、usage——再调 `makeTensor` 产出资源，随后 rank/dimensions 可逐维读取。

```swift
let desc = MTLTensorDescriptor()
desc.dataType = .float32
desc.dimensions = MTLTensorExtents(__rank: 3, values: [4, 8, 6])
desc.usage = [.compute]
let tensor = try device.makeTensor(descriptor: desc)
// tensor.rank / tensor.dimensions 逐维读取
```

- `dimensions` 用 MTLTensorExtents 按 rank 加数组构造，声明逻辑形状 [4,8,6]。
- `dataType` 定元素类型（float32 为 4 字节浮点；还有 bfloat16 等机器学习常用的 16 位浮点格式）。
- `usage` 是位掩码（多个开关位合并成一个整数），声明这张张量将用于 compute（计算）/render/机器学习中的哪些路径——驱动据此决定布局与分配方式。

**stride 对齐是 ML 用途的硬性要求。** 当 usage 含 MachineLearning 时，第 2 维的 stride 按 64 字节对齐——硬件对张量布局有明确要求，这与纹理的行对齐（每行字节数必须对齐到指定粒度）同源。

对齐让每行数据落在 GPU 的访问粒度上，避免机器学习算子的非对齐访问惩罚。这也意味着：张量的实际内存布局不能总按"shape 连乘 × 元素大小"推算。

**默认 private 分配是实测到的能力边界。** 本实验创建的张量，底层 `tensor.buffer` 为 nil：private（GPU 独享、CPU 无法直接读写的分配方式）意味着 CPU 侧的 `replace`/`getBytes` 这对读写方法不会生效。

数据进出要走 GPU 路径——Shader ML 内核或 ML Command Encoder（见 lab 28 / lab 29）。

这样设计的原因：机器学习数据面以 GPU 吞吐为主，CPU 访问走显式 GPU 路径更利于调度。

你在真实输出里看到的 `buffer = nil（private 分配）`，正来自这里的分配机制；`元素总数 = 192（768 字节）` 则说明本例 usage 只有 compute、未触发 ML 对齐，布局仍是紧凑连乘。

## Pitfalls & Q&A

**1. CPU 侧读写张量没有效果，或以为拿到的是空张量。**
现象：调用 `replace`/`getBytes` 后数据不变，或看到 `tensor.buffer` 为 nil 以为创建失败。原因：张量默认 private 分配，CPU 无法直接访问（本实验实测）。

解法：数据读写改走 GPU 路径——用 Shader ML 内核或 ML Command Encoder 处理数据，而不是从 CPU 直碰内存。

**2. 手算的字节偏移在 ML 用途下读错数据。**
现象：按"shape 连乘 × 元素大小"推算的偏移，访问到的元素不对。原因：usage 含 MachineLearning 时第 2 维 stride 按 64 字节对齐，物理布局不再与逻辑形状紧凑对应。

解法：依赖张量自身的 shape/stride 语义做定位与切片，不要手算偏移。

**Q：MTLTensor 相比 MTLBuffer 的核心增量是什么？**
三点：内建的维度语义（shape/rank 随资源走）、ML 用途的 stride 对齐由驱动处理、与 ML 编码器及 Shader ML 的原生集成。反过来，只要数据是一维且不需要 ML 路径，buffer 仍是更简单的选择。

**Q：为什么张量默认 private，而不是给 CPU 一个可直接读写的指针？**
机器学习数据面以 GPU 吞吐为主，绝大多数张量终生只在 GPU 上流转。默认 private 让驱动按 GPU 最优方式分配；需要 CPU 参与的场景走显式 GPU 路径，调度时机更可控。
