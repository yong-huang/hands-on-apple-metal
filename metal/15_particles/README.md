# 15 · GPU 粒子系统：一万个粒子的 GPU 自治

> 一个粒子是几个浮点数，一万个粒子就是一个"活的系统"。
> 本实验让 compute 每帧积分一万组位置/速度，渲染管线把它们画成点——
> CPU 全程只递一个时间步长，粒子的生死弹跳全在 GPU 上自治。

## 1. 为什么需要它

粒子系统是"状态性 GPU 计算"的最小完整案例：compute 跨帧更新状态缓冲，render 消费同一缓冲。它与 16 的"无状态生成"互为镜像——理解两者的边界，就理解了 GPU 计算的任务分类。

## 2. 总览：核心机制一图看懂

![粒子系统数据流](images/particles.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/15_particles/images/particles.html)（或本地打开 [`images/particles.html`](images/particles.html)）。

位置/速度两块缓冲喂给 compute 积分，新位置直接供渲染画点。一句话心智模型：**缓冲即世界状态，kernel 即物理定律**。

## 3. 快速开始

```bash
./particles.sh               # 一条龙
AUTO_QUIT=6 ./particles.sh observe   # 观察六秒烟花
```

控制台输出（真实）：

```
粒子数: 10000，compute 每帧更新位置/速度，render 画 10000 个点
```

窗口中粒子从中心炸开、撞墙反弹，颜色随速度从青到橙。验证方法：改反弹边界为 0.5，粒子活动范围立刻收缩——物理规则确实住在 kernel 里。

## 4. 核心概念

### 4.1 状态外置

粒子没有类、没有对象——只有 `positions[]` 与 `velocities[]` 两块缓冲。每个线程以自己的 `i` 读写对应槽位，天然无锁（数据并行的一写一读）。

### 4.2 欧拉积分 + 反弹

`p += v * dt`，然后四面墙各做一次"位置钳回 + 速度取反"。物理正确性不重要，**状态更新模式的完整性**才重要。

### 4.3 point 图元

`drawPrimitives(type: .point, vertexCount: 10000)`：每个顶点渲染成一个方形点，大小由 vertex shader 的 `[[point_size]]` 控制。点精灵是 GPU 可视化的万金油。

### 4.4 颜色编码速度

`speed → clamp → 颜色插值`：把不可见的速度场变成可见的色彩。**可视化即调试**——这条经验贯穿所有 GPU 数值程序。

## 5. 关键 API 与字段

```swift
// Pass 1：compute 积分
enc.dispatchThreadgroups(...threadsPerThreadgroup: MTLSize(width: 256, ...))
// Pass 2：同一 commandBuffer 里消费
enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
```

两趟编码进同一个 commandBuffer：GPU 保证 compute 先于 render——无需 CPU 插手等待。

## 6. 文件结构

```
15_particles/
├── README.md                    # 本文档
├── particles.sh                 # 主演示脚本
├── main.swift                   # 入口包装：调 runParticles()
├── particles.swift              # 实验程序：积分内核 + 点渲染
└── images/
    ├── particles.dataflow.json  # 图源
    ├── particles.html           # 交互版
    └── particles.svg            # 双主题矢量版
```

## 7. 面试要点

- **粒子系统为什么适合 GPU？** 万级粒子彼此独立、同构更新——数据并行的教科书场景；CPU 循环一帧就到瓶颈。
- **compute 与 render 如何保证顺序？** 同一 commandBuffer 内按编码顺序执行；跨 buffer 才需要事件/栅栏。
- **状态的读写竞争？** 每线程只读写自己的槽位（以索引划分），无共享无竞争——结构化避免锁。
- **dt 为什么用 Uniform？** 全局一致、每帧变化、体积极小——正是 Uniform 的定义性场景。

## 8. 总结

有状态计算 + 渲染消费的闭环跑通。下一篇做减法：去掉状态，让 kernel 纯粹"生成"几何，看重叠编排的另一种形态。

→ 下一篇：[16 · Compute→Render](../16_compute_to_render/README.md)
