# 09 · Bloom 辉光：三滤镜组合拳

> 单个滤镜是零件，组合才是机器。Bloom（辉光）= 提取高光 → 晕开 → 叠回原图，
> 三条 MPS 滤镜串成一条流水线——游戏画面里霓虹灯、魔法特效的来源。

## 1. 为什么需要它

真实效果从不由单个算子完成。Bloom 演示了算子组合的两个关键问题：**中间数据怎么流转**（纹理接力）与**组合语义怎么验证**（亮点该有辉光、暗点不该有）。

## 2. 总览：核心机制一图看懂

![Bloom 数据流](images/bloom.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/09_bloom/images/bloom.html)（或本地打开 [`images/bloom.html`](images/bloom.html)）。

场景图依次流过阈值、模糊、加法三站，辉光图叠回原图。一句话心智模型：**高光提取后糊开再贴回去**。

## 3. 快速开始

```bash
./bloom.sh           # 一条龙
```

真实输出：

```
原图光晕环亮度: 10 → Bloom 后: 54（亮点周围）
暗点同位置: 12（应仍接近背景 10）
✅ Bloom 验证通过：只有高光产生辉光
```

验证方法：在亮点外 17 像素处采样"光晕环"——Bloom 后变亮；同位置的暗点光晕环保持背景值。正反两个断言锁死语义。

## 4. 核心概念

### 4.1 三段流水线

`ThresholdToZero(0.3)`：低于阈值清零，只留高光。`GaussianBlur(8)`：把点光源晕成光斑。`Add`：辉光叠回——过曝即"辉光感"。

### 4.2 中间纹理即传送带

每段滤镜的输出是下段的输入，三张中间纹理就是流水线的传送带。编码进同一命令缓冲，GPU 按序执行无需 CPU 等待。

### 4.3 正反断言

只验证"亮点变亮"不够——阈值失效时暗点也会漏辉光。正反双断言（亮点环变亮 ∧ 暗点环不变）才能锁死语义。

### 4.4 易错点

- 辉光环采样距离要落在模糊半径内（sigma=8 → ~17px 处仍有响应）。
- 8-bit 输出饱和：叠加后 >255 会截断，专业实现用 float 纹理。

## 5. 关键 API 与字段

```swift
threshold.encode(commandBuffer: cb, sourceTexture: scene, destinationTexture: bright)
blur.encode(commandBuffer: cb, sourceTexture: bright, destinationTexture: blurred)
add.encode(commandBuffer: cb, primaryTexture: scene, secondaryTexture: blurred, resultTexture: final)
```

## 6. 文件结构

```
09_bloom/
├── README.md             # 本文档
├── bloom.sh              # 主演示脚本
├── main.swift            # 入口包装
├── bloom.swift           # 实验程序：场景合成 + 三滤镜 + 双断言
└── images/
    ├── bloom.dataflow.json # 图源
    ├── bloom.html          # 交互版
    └── bloom.svg           # 双主题矢量版
```

## 7. 深入要点

- **Bloom 的阈值语义？** ThresholdToZero 保留超阈值的原值（而非置 255）——高光强度信息保留，辉光才有层次。
- **流水线中间数据的显存管理？** 每段一张纹理即可复用池化；同一命令缓冲内生命期由 GPU 顺序保证。
- **为什么辉光会过曝？** Add 后超过 1.0 截断——HDR 管线用 float 纹理 + 色调映射解决。

## 8. 总结

三滤镜流水线立住。下一篇回到最简单的算子——二值化，练习"解析解验证"的方法论。

→ 下一篇：[10 · 阈值二值化](../10_threshold/README.md)
