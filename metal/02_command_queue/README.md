# 02 · 第一个命令队列：GPU 是异步执行的

> 上一篇拿到了 `MTLDevice` 钥匙，但 GPU 还没动过一下——因为 Metal 是一套**命令驱动的异步架构**：
> CPU 不直接调用 GPU，而是把命令"装箱"提交给队列，GPU 按自己的时间线消费。
> 本实验用 20 行代码走通 `make → commit → completed` 的完整生命周期。

## 1. 为什么需要它

如果 CPU 每发一条指令都等 GPU 干完，处理器就白瞎了。Metal 的解法是把"下达命令"和"执行命令"彻底解耦：CPU 把命令编码进缓冲区就返回，GPU 在另一条时间线上异步消费。理解这个模型是理解后面所有渲染/计算实验的前提——否则你会不明白为什么 `waitUntilCompleted()` 这种"同步点"如此关键。

## 2. 总览：核心机制一图看懂

![命令缓冲的一生](images/command_queue.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/metal/02_command_queue/images/command_queue.html)（或本地打开 [`images/command_queue.html`](images/command_queue.html)）。

三层骨架：`MTLDevice` 创建 `MTLCommandQueue`（生产线），队列生产 `MTLCommandBuffer`（集装箱），缓冲经 `commit()` 入队由 GPU 异步执行。一句话心智模型：**队列是提交通道，缓冲是执行单元，`commit()` 是 CPU 时间线与 GPU 时间线的分界线**。

## 3. 快速开始

```bash
./command_queue.sh          # 一条龙：build → observe → clean
./command_queue.sh observe  # 只运行
```

真实输出：

```
=====> [observe] 运行实验（程序输出即观察结果）
=== Program 2: Command Queue ===
GPU Device: Apple M5 Pro
Command Queue created
Command Buffer: MyFirstCommandBuffer
Command Buffer committed
Command Buffer completed

实验结束。
```

验证方法：`committed` 打印后程序并没有卡住——CPU 立即继续往下走，直到 `waitUntilCompleted()` 才等 GPU；这两行日志的先后就是异步模型最直接的证据。

## 4. 核心概念

### 4.1 `MTLCommandQueue`——命令队列（生产线）

由 `device.makeCommandQueue()` 创建，内部维护 GPU 任务队列，线程安全；可以并发提交多个缓冲。一个 App 通常只建一个队列，长期复用。

### 4.2 `MTLCommandBuffer`——命令缓冲区（集装箱）

由 `queue.makeCommandBuffer()` 创建，是真正要执行的指令集合（绘制调用、计算任务等）。本实验的缓冲是**空的**——连一个 encoder 都没创建，但 `commit()` 后 GPU 依然完整走了"排队→执行→完成"一趟。这正好证明：提交空缓冲也是合法的 GPU 任务，机制已经跑通。

### 4.3 生命周期四阶段

`创建 → 编码（本实验省略）→ commit 提交 → completed 完成`。`label` 属性（`"MyFirstCommandBuffer"`）在 Xcode GPU 调试器里可见，多缓冲场景下是排查利器——好习惯从第一个缓冲就养成。

### 4.4 易错点

- `commit()` 之后**不要再往缓冲里编码**，缓冲已冻结。
- `waitUntilCompleted()` 是 CPU 阻塞等待；渲染循环里几乎不用它（用 drawable 机制），计算场景读结果前必须等。
- 队列很贵、缓冲便宜：队列建一次，缓冲每次任务新建。

## 5. 关键 API 与字段

```swift
let queue = device.makeCommandQueue()          // 提交通道：建一次用到底
let buffer = queue.makeCommandBuffer()         // 执行单元：每次任务一个
buffer.label = "MyFirstCommandBuffer"          // 调试标记：GPU 帧调试器里可见
buffer.commit()                                // 冻结并送入 GPU 时间线（异步）
buffer.waitUntilCompleted()                    // CPU 同步点：等到 GPU 干完
```

为什么 `commit()` 与 `completed` 之间 CPU 还能打印日志：`commit()` 只是把缓冲交给驱动排队，不等执行——这就是 4.2 说的"两条时间线"。

## 6. 文件结构

```
02_command_queue/
├── README.md                          # 本文档
├── command_queue.sh                   # 主演示脚本：build → observe → clean
├── main.swift                         # 入口包装：调用 runCommandQueue()
├── command_queue.swift                # 实验程序本体：三层骨架最小演示
└── images/
    ├── command_queue.sequence.json    # 图源（Typed JSON IR）
    ├── command_queue.html             # 交互版时序图（浏览器打开）
    └── command_queue.svg              # 双主题矢量版（README 内嵌）
```

## 7. 深入要点

- **Metal 命令提交的层次？** Device → CommandQueue → CommandBuffer → CommandEncoder → commit；队列管排队，缓冲装命令，编码器往缓冲里写具体指令。
- **`commit()` 后命令何时执行？** 异步。CPU 立即返回，GPU 在自己的时间线上按序消费队列里的缓冲。
- **CPU 怎么知道 GPU 干完了？** `waitUntilCompleted()`（阻塞）或 addCompletedHandler（回调）；渲染场景靠 `present(drawable)` 与 CAMetalLayer 同步。
- **为什么队列要复用、缓冲每次新建？** 队列绑定驱动资源且线程安全，创建昂贵；缓冲是一次性容器，用完即弃。

## 8. 总结

GPU 的"快递系统"已经跑通：装箱（编码）、发货（commit）、签收（completed）。但缓冲里还是空的——下一篇塞进真正的货：用渲染管线画第一个三角形。

→ 下一篇：[03 · 第一个三角形](../03_triangle/README.md)
