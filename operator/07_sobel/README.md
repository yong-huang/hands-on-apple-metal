# 07 · MPS Sobel 边缘检测

> 从本篇起用"现成的轮子"：Metal Performance Shaders 提供苹果调优过的算子族。
> Sobel 是最小的入门：三行 API 完成边缘检测，再用像素回读验证"轮子是对的"。

## 1. 为什么需要它

写算子之前先学会用算子。MPS 的价值：免去 kernel 编写/调优/适配三代硬件的工作。Sobel 作为最经典的图像算子，是理解 MPS 用法（建滤镜 → encode → commit）的最佳起点。

## 2. 总览：核心机制一图看懂

![Sobel 数据流](images/sobel.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/07_sobel/images/sobel.html)（或本地打开 [`images/sobel.html`](images/sobel.html)）。

合成测试图进 Sobel 滤镜出边缘响应图。一句话心智模型：**MPS 滤镜 = 免编写的算子，编码即调用**。

## 3. 快速开始

```bash
./sobel.sh           # 一条龙
```

真实输出：

```
边缘响应: 255 | 平坦区响应: 0
✅ Sobel 验证通过：边缘位置响应显著更强
```

验证方法：程序内生成"灰底白方块"图——方块边框是已知边缘、中心是已知平坦区，回读两处像素即可断言。

## 4. 核心概念

### 4.1 MPS 三步曲

`MPSImageSobel(device:)` 构造 → `encode(commandBuffer:source:destination:)` 编码 → commit。所有 MPS 滤镜共用这个骨架，换算子只换类名。

### 4.2 Sobel 的本质

两个 3×3 卷积核分别求 x/y 方向差分，梯度模长 `√(gx²+gy²)` 即边缘强度——方向导数的离散化。

### 4.3 合成测试图

验证的关键是**控制变量**：灰底 + 白方块让"哪里是边缘"有解析答案。用真实照片反而无法断言对错。

### 4.4 易错点

- MPS 输出纹理的 usage 要含 `.shaderWrite`（滤镜写入目标）。
- rgba8Unorm 输出的值域经过变换，比较用相对大小而非绝对值。

## 5. 关键 API 与字段

```swift
let sobel = MPSImageSobel(device: device)
sobel.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: dst)
cb.commit(); cb.waitUntilCompleted()
```

## 6. 文件结构

```
07_sobel/
├── README.md              # 本文档
├── sobel.sh               # 主演示脚本
├── main.swift             # 入口包装
├── sobel.swift            # 实验程序：测试图 + 滤镜 + 回读验证
└── images/
    ├── sobel.dataflow.json# 图源
    ├── sobel.html         # 交互版
    └── sobel.svg          # 双主题矢量版
```

## 7. 面试要点

- **MPS 与自写 kernel 的取舍？** MPS 零维护、跨代调优；自写赢在差异化与融合自由度。通用算子用 MPS，差异化后处理自写（见 29）。
- **Sobel 为什么用两个方向核？** 边缘有方向性，x/y 差分合成梯度向量，模长才是与方向无关的边缘强度。
- **为什么用合成图验证？** 边缘位置有解析解，验证可以全自动断言。

## 8. 总结

MPS 三步曲入门。下一篇给 sigma 拧旋钮——看模糊强度如何被参数化验证。

→ 下一篇：[08 · 高斯模糊](../08_gaussian_blur/README.md)
