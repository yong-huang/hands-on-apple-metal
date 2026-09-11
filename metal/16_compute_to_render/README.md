# 16 · Compute → Render：同一命令缓冲的编排

> 15 的粒子有"记忆"（跨帧累积状态）；这次反过来——
> compute 无状态地一次性生成几何，render 在同一个命令缓冲里直接消费。
> 没有中间 CPU，没有同步等待：GPU 时间线的顺序就是同步。

## 1. 为什么需要它

程序化几何（波面、粒子轨迹、程序化地形）都是"算出来的顶点"。掌握 compute 产几何、render 吃几何的最短路径，就掌握了 GPU 程序化建模的骨架。本实验同时演示命令编码顺序即执行顺序这一关键语义。

## 2. 总览：核心机制一图看懂

![Compute→Render 编排](images/compute_to_render.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/16_compute_to_render/images/compute_to_render.html)（或本地打开 [`images/compute_to_render.html`](images/compute_to_render.html)）。

同一命令缓冲里先编码 compute 再编码 render，顶点缓冲是两者的接合点。一句话心智模型：**编码顺序 = 执行顺序**。

## 3. 快速开始

```bash
./compute_to_render.sh               # 一条龙
AUTO_QUIT=6 ./compute_to_render.sh observe
```

真实输出：

```
  顶点[0] = (0.700, 0.000) |len|=0.7000 ✅
  顶点[64] = (-0.000, 0.700) |len|=0.7000 ✅
  顶点[128] = (-0.700, -0.000) |len|=0.7000 ✅
  顶点[192] = (0.000, -0.700) |len|=0.7000 ✅
✅ compute 生成的 256 个顶点全部落在半径 0.7 的圆上
```

窗口显示一个青色圆环。验证方法：回读的每个顶点模长都是 0.7000——"生成正确"由数学断言而非肉眼确认。

## 4. 核心概念

### 4.1 无状态生成

kernel 不记得上一帧：`顶点[i] = 圆公式(i)`。每次全量重算，代价是 256 次三角函数（微不足道），换来零状态管理。**有状态还是无状态，是 GPU 任务设计的第一决策。**

### 4.2 命令缓冲的顺序语义

compute encoder 先编码、render encoder 后编码 → GPU 严格按序执行。跨命令缓冲才需要事件/栅栏（见 30 的跨队列版本）。

### 4.3 lineStrip 图元

256 个顶点连成闭合折线。相比 triangle 的"填充"，线段可视化更直观暴露几何质量。

### 4.4 易错点

- 生成线程数不覆盖点数 → 圆有缺口（22 有专门的边界反例）。
- 在 render 前用 CPU 读缓冲 → 忘 `waitUntilCompleted` 读到旧数据。
- MSL 里 `M_PI_F` 才是 π 常量。

## 5. 关键 API 与字段

```swift
// 同一个 cb：先 compute 后 render
if let enc = cb.makeComputeCommandEncoder() { /* dispatch 256 线程 */ enc.endEncoding() }
if let enc = cb.makeRenderCommandEncoder(descriptor: pass) { /* draw lineStrip */ enc.endEncoding() }
cb.present(drawable); cb.commit()
```

生成内核输出按全局索引寻址（"以我编号写我的槽"）——op02 的索引语义在渲染场景的直接复用。

## 6. 文件结构

```
16_compute_to_render/
├── README.md                          # 本文档
├── compute_to_render.sh               # 主演示脚本
├── main.swift                         # 入口包装
├── compute_to_render.swift            # 实验程序：生成内核 + 线环渲染 + 回读
└── images/
    ├── compute_to_render.dataflow.json# 图源
    ├── compute_to_render.html         # 交互版
    └── compute_to_render.svg          # 双主题矢量版
```

## 7. 面试要点

- **同命令缓冲的 compute/render 需要同步吗？** 不需要：GPU 按编码顺序执行，资源依赖天然满足。
- **有状态 vs 无状态更新的取舍？** 有状态省计算但引入时间依赖；无状态可重算、可回放、易并行——按需选择。
- **程序化几何相比建模导入的优势？** 参数化、分辨率无关、零资产体积；代价是 ALU 开销与表达力边界。
- **如何验证生成的几何？** 数学不变量（模长/对称性）+ CPU 回读——比截图更可靠。

## 8. 总结

同缓冲编排的最短闭环完成。现在可以挑战真正的"大家伙"了：换掉整个渲染范式，用光线追踪重新成像。

→ 下一篇：[21 · 光线追踪](../21_raytracer/README.md)
