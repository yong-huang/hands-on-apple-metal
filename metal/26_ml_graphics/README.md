# 26 · ML + 图形混合管线：跨队列编排

> 混合管线的难点从来不是"跑"，而是"同步"：ML 输出必须先于图形消费。
> 本实验用 MTL4 计算队列 + MTLSharedEvent + 传统渲染队列，
> 把这条同步骨架完整真跑一遍——ML 派发的插槽原位预留。

## 1. 为什么需要它

AI 生成内容（超分、神经材质、生成式贴图）都在走"推理 → 渲染"的流水线。跨队列顺序、事件同步、数据面交接是这类管线的通用骨架——骨架立住，ML 插件即插即用。

## 2. 总览：核心机制一图看懂

![混合管线数据流](images/ml_graphics.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/26_ml_graphics/images/ml_graphics.html)（或本地打开 [`images/ml_graphics.html`](images/ml_graphics.html)）。

MTL4 队列生成数据面并 signal 事件，渲染队列 encodeWait 后采样。一句话心智模型：**事件是队列之间的红绿灯**。

## 3. 快速开始

```bash
./ml_graphics.sh               # 一条龙
AUTO_QUIT=6 ./ml_graphics.sh observe
```

真实输出：

```
编排：计算队列生成数据 → SharedEvent 信号 → 渲染队列等信号后采样
数据面回读: 角=(-0.10,0.30,0.20) 中心=(0.90,0.55,0.50)
✅ 混合管线验证通过：跨队列同步后数据面内容正确
```

窗口显示 GPU 生成的径向渐变。验证方法：数据面数值与径向公式逐位吻合（角落 d≈1 → 红通道≈0；中心 d≈0 → 0.9）。

## 4. 核心概念

### 4.1 跨队列顺序 = 事件

MTL4 队列 `signalEvent(event, value:1)` 排在其已提交工作之后；传统渲染队列 `cb.encodeWaitForEvent(event, value:1)` 卡住后续命令。CPU 全程不介入——这是 GPU 时间线原生的先后关系。

### 4.2 MTL4 的资源纪律（实测踩坑）

纹理进 ResidencySet 之前，MTL4 队列的写入被**静默丢弃**——画面全黑无报错。登记后一切正常。资源常驻不是可选项。

### 4.3 数据面缓冲

512×512 float4 共享缓冲：MTL4 计算写、渲染片元按像素索引读、CPU 直接回读验证——三方共享同一块统一内存。

### 4.4 ML 插槽

生成内核所在的位置就是 ML 派发位（28 的编码器就绪后原位替换），数据面契约（缓冲布局）不变。

## 5. 关键 API 与字段

```swift
argTable.setTexture(dataTexture.gpuResourceID, index: 0)   // MTL4 也走参数表
m4.commit([cmdBuf]); m4.signalEvent(event, value: 1)
// 渲染侧（传统队列）：
cb.encodeWaitForEvent(event, value: 1)
```

## 6. 文件结构

```
30_ml_graphics/
├── README.md                     # 本文档
├── ml_graphics.sh                # 主演示脚本
├── main.swift                    # 入口包装：调 runMlGraphics()
├── ml_graphics.swift             # 实验程序：MTL4 计算 + 事件 + 渲染消费
└── images/
    ├── ml_graphics.dataflow.json # 图源
    ├── ml_graphics.html          # 交互版
    └── ml_graphics.svg           # 双主题矢量版
```

## 7. 深入要点

- **跨队列同步有哪些手段？** 事件（值语义）、栅栏（缓冲级）、共享事件（可 CPU 等待）；本实验用共享事件贯穿三端。
- **CPU 不介入的同步有什么好处？** 无忙等、无时间片浪费，GPU 时间线自治——延迟更低。
- **混合管线的数据面怎么设计？** 统一内存缓冲 + 明确布局契约 + 单一写者——三方（ML/渲染/调试）共享不冲突。

## 8. 总结

渲染线（metal/）30 个项目全部实现完毕：从设备枚举到 Metal 4 混合管线。转战算子线，从最小的心跳开始。

→ 转战算子线：[operator/03 · 向量点积规约](../../operator/03_reduction/README.md)
