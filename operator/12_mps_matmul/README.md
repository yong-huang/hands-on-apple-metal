# 12 · MPS 矩阵乘法：商业级 GEMM

> 05 的手写 Tiled 跑出 90 GFLOPS；换成 MPS 的 MPSMatrixMultiplication——
> 1270 GFLOPS。14 倍的差距就是"苹果十年 GEMM 调优"的具象化。
> 本实验学会正确使用它，并用这个数字校准对优化的敬畏。

## 1. 为什么需要它

会写 kernel 与会用最好的 kernel 是两种能力。生产代码永远优先 MPS/MetalFX 级实现；理解它的接口抽象（buffer+描述符=矩阵视图）与性能量级，才能判断"什么时候值得自己写"。

## 2. 总览：核心机制一图看懂

![MPS GEMM 数据流](images/mps_matmul.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/12_mps_matmul/images/mps_matmul.html)（或本地打开 [`images/mps_matmul.html`](images/mps_matmul.html)）。

两个 MPSMatrix 喂给乘法算子出结果矩阵，抽样验证 + 计时。一句话心智模型：**描述"乘什么"，不描述"怎么乘"**。

## 3. 快速开始

```bash
./mps_matmul.sh           # 一条龙
```

真实输出：

```
MPS GEMM 1024x1024x1024: 1.7 ms ≈ 1270 GFLOPS
  （对照：05 实验手写 Tiled 512³ ≈ 90 GFLOPS——商业内核与手写内核的差距就是优化空间）
✅ 128 个抽样点与 CPU 一致
```

验证方法：整数倍数据 + 128 点 CPU 抽样——性能碾压不豁免正确性。

## 4. 核心概念

### 4.1 MPSMatrix = buffer + 描述符

`MPSMatrixDescriptor(rows:columns:rowBytes:dataType:)` 定义"怎么读一块内存"——行距可以大于列数（子矩阵/切片零拷贝）。矩阵是视图，不是拷贝。

### 4.2 一次描述，内核全托管

构造时给出 resultRows/Columns、interiorColumns、alpha/beta；encode 时只传左右矩阵与结果。内核选择（tile/精度/代际适配）全由 MPS 决定。

### 4.3 性能数字的解读

1270 GFLOPS @ 1024³ FP32。06 的算力上限实测 2.26 TFLOPS——MPS 跑出了理论值的 56%，而这个数字本身还在随矩阵增大爬升。

### 4.4 易错点

- 忘预热：首轮含内核选择/编译，计时应预热后进行。
- beta 语义：非 0 时 C 参与累加（C = alpha·A·B + beta·C），复用结果缓冲时最容易踩。

## 5. 关键 API 与字段

```swift
let gemm = MPSMatrixMultiplication(device: device, transposeLeft: false, transposeRight: false,
                                   resultRows: M, resultColumns: N, interiorColumns: K, alpha: 1, beta: 0)
gemm.encode(commandBuffer: cb, leftMatrix: matA, rightMatrix: matB, resultMatrix: matC)
```

## 6. 文件结构

```
12_mps_matmul/
├── README.md                   # 本文档
├── mps_matmul.sh               # 主演示脚本
├── main.swift                  # 入口包装
├── mps_matmul.swift            # 实验程序：MPSMatrix + GEMM + 验证计时
└── images/
    ├── mps_matmul.dataflow.json# 图源
    ├── mps_matmul.html         # 交互版
    └── mps_matmul.svg          # 双主题矢量版
```

## 7. 面试要点

- **MPSMatrix 为什么是视图不是值？** 与 texture 同源的设计：内存归你管，语义由描述符声明——零拷贝切片的前提。
- **beta ≠ 0 的用途？** 累加进既有结果（如多层并行累加、residual 连接的批量实现）。
- **什么时候自己写 GEMM？** 需要非常规融合（自定义 epilogue）、特殊布局或量化格式时；通用 FP32 永远先用 MPS。

## 8. 总结

见过天花板才能正确仰望。下一篇回归手写：用 float4 向量化把逐元素加法打到 75 GB/s。

→ 下一篇：[13 · 逐元素加法](../13_mps_elementwise/README.md)
