# 29 · 自定义滤镜：自研内核接入 MPS 流水线

> MPS 没有"油画效果"滤镜？那就自己写一个 posterize（色彩量化）内核，
> 前面接 MPS 高斯模糊去噪——现成算子做前处理、自研内核做差异化，
> 这就是滤镜开发的标准分工。

## 1. 为什么需要它

滤镜开发 = "MPS 现成的 80% + 自研的 20%"。本实验验证两件事：自定义内核能与 MPS 滤镜无缝串联（纹理自然流转）；自研部分的效果可以被统计断言（256 级 → 恰好 4 级）。

## 2. 总览：核心机制一图看懂

![自定义滤镜数据流](images/custom_filter.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/operator/29_custom_filter/images/custom_filter.html)（或本地打开 [`images/custom_filter.html`](images/custom_filter.html)）。

渐变图先过 MPS 模糊再进 posterize 量化，输出灰度级统计验证。一句话心智模型：**posterize = floor(c/step)*step + step/2，色彩塌缩到级中心**。

## 3. 快速开始

```bash
./custom_filter.sh           # 一条龙
```

真实输出：

```
输入灰度级: 256 → 输出灰度级: [32, 96, 159, 223]
✅ 自定义滤镜验证通过：posterize 量化到 ≤4 级，并与 MPS 模糊无缝串联
```

验证方法：输出中不同灰度值的集合恰好 ≤ LEVELS 个——量化语义的解析断言（若 MPS 模糊未生效，渐变的边缘级数会泄露）。

## 4. 核心概念

### 4.1 posterize 内核

```metal
float3 q = floor(c.rgb / step) * step + step * 0.5;
```

除以级宽取整再乘回，加半级偏移让色彩落在"级的中心"——油画/像素风滤镜的基础件。

### 4.2 与 MPS 的衔接

MPS 滤镜输出纹理 → 自定义 compute 读入（`access::read`）→ 写出目标纹理。texture 在两种内核间流转，无需任何转换——纹理就是通用接口。

### 4.3 验证设计

渐变输入在模糊后仍是平滑的 → posterize 后每通道只可能出现 LEVELS 个值。输入的可预测性换来验证的解析性（10 的方法论）。

## 5. 关键代码

```swift
blur.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: mid)   // MPS 前处理
enc.setComputePipelineState(posterizePSO)                                      // 自研后处理
enc.setTexture(mid, index: 0); enc.setTexture(dst, index: 1)
enc.setBytes(&levels, length: 4, index: 0)
```

## 6. 文件结构

```
29_custom_filter/
├── README.md                     # 本文档
├── custom_filter.sh              # 主演示脚本
├── main.swift                    # 入口包装
├── custom_filter.swift           # 实验程序：MPS 模糊 + posterize + 统计验证
└── images/
    ├── custom_filter.dataflow.json # 图源
    ├── custom_filter.html          # 交互版
    └── custom_filter.svg           # 双主题矢量版
```

## 7. 深入要点

- **滤镜开发的分工原则？** 通用前处理交给 MPS（调优免费），差异化后处理自写（效果可控）。
- **posterize 与量化的关系？** 就是均匀标量量化——量化感知训练/后训练量化是同一数学在权重复用。
- **为什么用灰度级数做断言？** 集合基数是量化效果的充分统计量，且对图像内容鲁棒。

## 8. 总结

滤镜开发模式确立。最后一站：把整个系列的基准测试规范化。

→ 下一篇：[30 · 算子基准测试](../30_benchmark/README.md)
