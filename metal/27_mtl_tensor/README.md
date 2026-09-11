# 27 · Metal 4 · MTLTensor

> Metal 4 把"张量"升格为一等资源：比 buffer 多出 shape/strides 语义，
> 是 Shader ML 与 ML Command Encoder 的原生数据面。
> 本机 macOS 26.5 已可真跑——本实验如实记录能力边界。

## 1. 为什么需要它

机器学习的数据天生是 N 维的。以前要靠约定（"前 4 字节是行数"）在 buffer 上硬造张量语义；MTLTensor 让维度成为资源自身的属性——AI 管线的数据流从此有了原生表达。

## 2. 总览：核心机制一图看懂

![MTLTensor 数据流](images/mtl_tensor.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/27_mtl_tensor/images/mtl_tensor.html)（或本地打开 [`images/mtl_tensor.html`](images/mtl_tensor.html)）。

描述符声明维度与类型，`makeTensor` 产出张量，能力探测记录访问边界。一句话心智模型：**MTLTensor = 知道自己形状的内存**。

## 3. 快速开始

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

验证方法：路线图的验收标准即"创建张量并打印维度属性"——shape/rank/dataType 全部打印即达成。

## 4. 核心概念

### 4.1 描述符三要素

`dimensions`（MTLTensorExtents，按 rank+数组构造）、`dataType`（float32/bfloat16…）、`usage`（compute/render/machine learning 位掩码）。

### 4.2 ML 用途的 stride 对齐

usage 含 MachineLearning 时，第 2 维的 stride 按 64 字节对齐——硬件对张量布局有硬性要求，与 texture 的行对齐同源。

### 4.3 实测记录：CPU 访问不可用

张量默认 private 分配：`tensor.buffer` 为 nil，CPU 侧 `replace/getBytes` 不生效（实测）。数据读写要走 GPU 路径（Shader ML 内核或 ML Command Encoder——见 28/29）。

### 4.4 与 buffer 的对照

同样的 768 字节，buffer 只知道长度；张量知道 [4,8,6]——"带形状的内存"让 reshape/切片成为元数据操作。

## 5. 关键 API 与字段

```swift
let desc = MTLTensorDescriptor()
desc.dataType = .float32
desc.dimensions = MTLTensorExtents(__rank: 3, values: [4, 8, 6])
desc.usage = [.compute]
let tensor = try device.makeTensor(descriptor: desc)
// tensor.rank / tensor.dimensions 逐维读取
```

## 6. 文件结构

```
27_mtl_tensor/
├── README.md                     # 本文档
├── mtl_tensor.sh                 # 主演示脚本
├── main.swift                    # 入口包装：调 runMtlTensor()
├── mtl_tensor.swift              # 实验程序：创建 + 属性打印 + 能力探测
└── images/
    ├── mtl_tensor.dataflow.json  # 图源
    ├── mtl_tensor.html           # 交互版
    └── mtl_tensor.svg            # 双主题矢量版
```

## 7. 面试要点

- **MTLTensor 相比 MTLBuffer 的增量？** 内建维度语义、ML 对齐 stride、与 ML 编码器/Shader ML 的原生集成。
- **为什么张量默认 private？** ML 数据面以 GPU 吞吐为主；CPU 访问走显式 GPU 路径更利于调度。
- **stride 对齐为什么是 64 字节？** 与 GPU 缓存行/合作社组访问粒度对齐，避免 ML 算子的非对齐惩罚。

## 8. 总结

Metal 4 数据面就位。下一篇上新命令栈——Allocator、参数表、ResidencySet，并诚实探测 ML 派发的那块拼图。

→ 下一篇：[28 · MTL4 命令栈](../28_ml_encoder/README.md)
