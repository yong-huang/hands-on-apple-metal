# 13 · 逐元素加法：带宽实测

> 逐元素算子是最"无聊"也最诚实的一类：性能天花板就是显存带宽。
> 本实验用 float4 向量化手写 A+B，看它离 06 实测的 220 GB/s 有多远。

## 1. 为什么需要它

逐元素算子占推理算子数量的多数（偏置/激活/缩放），个个都是带宽受限。掌握"向量化搬运 + 带宽对标"的手法，等于掌握了一类算子的全部优化逻辑。

## 2. 总览：核心机制一图看懂

![逐元素加法数据流](images/mps_elementwise.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/13_mps_elementwise/images/mps_elementwise.html)（或本地打开 [`images/mps_elementwise.html`](images/mps_elementwise.html)）。

A/B 两块 16MB 缓冲经 float4 加法内核写入 C。一句话心智模型：**算术强度 0.5 的算子，优化 = 把带宽打满**。

## 3. 快速开始

```bash
./mps_elementwise.sh           # 一条龙
```

真实输出：

```
加法 2048x2048（float4 向量化）: 0.67 ms ≈ 75 GB/s
  对照 06 实测带宽上限 ~220 GB/s——逐元素算子的性能天花板就是它
✅ 128 点抽样与 CPU 一致
```

验证方法：128 点抽样比对 + 换算带宽对标 06 的实测上限——性能与正确性双回归。

## 4. 核心概念

### 4.1 MPS 的边界（诚实记录）

MPS 没有"矩阵加法"的公开类（二元算子需子类化 MPSMatrixBinaryKernel）。生产实践两条路：手写 kernel（本实验）或 MPSGraph（11）。本实验用手写内核展示向量化手法。

### 4.2 float4 向量化

`device const float4*` 让每线程一次搬 16 字节 ×3（读 A/B、写 C）。指令数 ÷4、访存粒度对齐缓存行——75 GB/s vs 标量版 ~30 GB/s。

### 4.3 MPSMatrix 的复用

数据仍装在 MPSMatrix（buffer+描述符）里——`.data` 取出底层缓冲直接绑定 kernel。抽象层与手写内核不冲突。

### 4.4 与 06 对标的方法

带宽 = 3×16MB ÷ 耗时。75/220 ≈ 34%：单 kernel 未达上限属正常（启动开销、占用率），多算子流水或更大规模才能逼近。

## 5. 关键代码

```metal
kernel void mat_add(device const float4* a [[buffer(0)]],
                    device const float4* b [[buffer(1)]],
                    device float4* c [[buffer(2)]],
                    uint i [[thread_position_in_grid]]) {
    c[i] = a[i] + b[i];      // 一条指令完成四个加法
}
```

## 6. 文件结构

```
13_mps_elementwise/
├── README.md                      # 本文档
├── mps_elementwise.sh             # 主演示脚本
├── main.swift                     # 入口包装
├── mps_elementwise.swift          # 实验程序：向量化加法 + 带宽实测
└── images/
    ├── mps_elementwise.dataflow.json # 图源
    ├── mps_elementwise.html          # 交互版
    └── mps_elementwise.svg           # 双主题矢量版
```

## 7. 面试要点

- **逐元素算子的优化要点？** 向量化访存粒度、占用率拉满、避免不必要的中间物化（融合）。
- **为什么单 kernel 打不满带宽？** 启动/尾波开销、每组资源限制；持续流水的算子链才能逼近上限。
- **MPS 没有的算子怎么办？** 手写 kernel（本例）或 MPSGraph 组合（11），按融合需求选择。

## 8. 总结

Swift/Metal 侧的算子基础训练（03-13）收官。接下来换一把趁手的武器：苹果为 Apple Silicon 而生的 MLX。

→ 下一篇：[14 · MLX 数组与统一内存](../14_mlx_metal/README.md)
