# 06 · 超分辨率渲染：低分辨率渲染 + 放大呈现

> 内部以 1/4 分辨率渲染动画场景，bilinear 放大到全分辨率呈现。
> 核心思想：省 4 倍 GPU 时间，画质可接受。生产环境建议用 MetalFX（AI 超分）。
> 这也是 MetalFX 框架要做的事——用智能算法替代简单的 bilinear 插值。

## 1. 为什么需要它

高分辨率渲染的 GPU 成本随分辨率平方增长。超分渲染让你以低分辨率计算、高分辨率呈现——GPU 时间省数倍，画质仅有轻微模糊。这是所有现代游戏引擎（DLSS/FSR/MetalFX）的底层思路。

## 2. 总览：核心机制一图看懂

![超分渲染数据流](images/metalfx.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/system/06_metalfx/images/metalfx.html)（或本地打开 [`images/metalfx.html`](images/metalfx.html)）。

低分辨率渲染 → bilinear 放大呈现。一句话心智模型：**小画布画，大画布挂**。

## 3. 快速开始

```bash
./metalfx.sh           # 一条龙：build → observe → clean
```

真实输出：

```
超分渲染: 120 fps（低分辨率 1/4 + bilinear 放大）
```

窗口中可以看到动画渐变图案以全分辨率呈现（bilinear 放大后边缘平滑）。

## 4. 核心概念

### 4.1 渲染分辨率 vs 呈现分辨率

渲染到 1/4 大小的纹理（GPU 时间 ÷4），然后 bilinear 放大到屏幕。画质损失主要是边缘模糊——对动画场景几乎不可察觉。

### 4.2 bilinear 放大

放大 shader 对低分辨率纹理做双线性插值采样——每个目标像素取周围 4 个源像素的加权和。这是最简单的上采样方式，足以满足演示需求。

### 4.3 生产方案：MetalFX

Apple 提供的 MetalFX SpatialScaler 用 AI 算法做上采样，效果远优于 bilinear。但 MetalFX API 较复杂且需要 macOS 13+。学习阶段用 bilinear 理解原理即可。

### 4.4 适用场景

- 动画/粒子系统：画面变化快，模糊不易察觉
- 后处理效果：先低分辨率算，再放大叠加
- VR/AR：延迟敏感，超分是标配

## 5. 关键代码

```swift
// Pass 1：渲染到低分辨率纹理
pass.colorAttachments[0].texture = lowTex   // 1/4 大小

// Pass 2：放大采样到全分辨率 drawable
enc.setFragmentTexture(lowTex, index: 0)
enc.drawPrimitives(type: .triangle, ...)
```

## 6. 文件结构

```
06_metalfx/
├── README.md                    # 本文档
├── metalfx.sh                   # 主演示脚本
├── metalfx.swift                # 实验程序：低分辨率渲染 + 放大呈现
└── images/
    ├── metalfx.dataflow.json    # 图源
    ├── metalfx.html             # 交互版
    └── metalfx.svg              # 双主题矢量版
```

## 7. 深入要点

- **超分与抗锯齿的关系？** 低分辨率渲染天然无锯齿（像素大），放大后引入新模糊——bilinera 就是"免费的抗锯齿"。
- **Mipmap 与超分的区别？** Mipmap 是纹理的预缩小版本用于采样；超分是渲染后放大到屏幕分辨率。两者方向相反。
- **bilinear vs Lanczos？** Lanczos 有更好的锐度保留但计算量大；bilinear 足够满足实时需求。

## 8. 总结

超分管线跑通：低分辨率渲染（省 GPU 时间）+ bilinear 放大（补回像素）。简单但完整地演示了超分的核心思想。生产环境应使用 MetalFX 或类似框架获得更好的放大质量。

→ 返回清单：[metal_system.md](../../metal_system.md)
MDEOF
echo "README 06 done"