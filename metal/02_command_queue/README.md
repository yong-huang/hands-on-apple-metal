# 02 · 第一个命令队列：GPU 是异步执行的

> Metal 是一套命令驱动的异步架构：CPU 不直接调用 GPU，而是把命令"装箱"提交给队列，GPU 在自己的时间线上消费。本实验用 20 行代码走通一条命令缓冲 `make → commit → completed` 的完整生命周期，并解释为什么 `commit()` 之后 CPU 不会卡住。

## Background

CPU 和 GPU 是两颗速度特征完全不同的处理器。最直接的合作方式是同步逐条配合：CPU 发一条绘制指令，停下来等 GPU 做完，再发下一条。

这种方式在真实渲染里会互相拖累。渲染一帧时，CPU 通常很快就能备好指令，GPU 却要更久才画完；等待期间 CPU 完全闲置。反过来 GPU 画完后，又得干等 CPU 发下一批。指令越密集，两颗处理器的空转越明显。

Metal 的解法是把"下达命令"与"执行命令"彻底解耦：CPU 把一批命令编码好提交出去就返回，GPU 在另一条时间线上异步消费。不理解这个模型，就看不懂 Metal 代码里那些同步点（等待 GPU 完成的调用）为什么存在、该放在哪里。

## What

Metal 的命令执行由两个对象承担：`MTLCommandQueue`（命令队列，CPU 提交命令的通道）和 `MTLCommandBuffer`（命令缓冲区，真正被 GPU 执行的一批指令）。队列由设备创建，缓冲由队列创建，缓冲经 `commit()` 提交后由 GPU 异步执行。

可以把这套机制想象成快递系统：队列是收件的物流线路，缓冲是装命令的集装箱，`commit()` 是发货扫描——CPU 时间线与 GPU 时间线由此分界。但和普通快递不同的是，同一队列里的缓冲严格按提交顺序执行，且"装箱"（编码）一经发货就不能再加东西。

三层骨架串起来是：`MTLDevice` 创建 `MTLCommandQueue`（生产线），队列生产 `MTLCommandBuffer`（集装箱），缓冲经 `commit()` 入队由 GPU 异步执行。**队列是提交通道，缓冲是执行单元，`commit()` 是两条时间线的分界线。**

## When to Use

这节回答：什么时候需要手动管理命令提交与同步，什么时候不用操心。

典型场景：

- 每帧渲染：CPU 把当帧的绘制命令编码进缓冲并 `commit()`，GPU 画当帧的同时 CPU 去准备下一帧，两颗处理器并行。
- 计算任务读结果：GPU 算完才能取数据，在读取前用同步调用等它完成。
- 多线程并行提交：队列是线程安全的（多个线程同时使用不会出错），可以让多个线程各自编码缓冲、并发提交。

何时不用：简单的一次性任务，直接同步等待即可，不必引入完成回调；标准 2D/3D 应用用更高层框架时，命令提交被框架托管，无需手动编码。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| CPU 绘制 | 无提交与同步问题；重负载下慢 | 数据量小、逻辑简单的绘制 |
| OpenGL / OpenGL ES | 状态机式调用，提交时机不显式；Apple 平台已废弃 | 维护历史跨平台代码 |
| SpriteKit / SceneKit | 框架托管命令提交，省心；自定义提交节奏空间小 | 标准 2D/3D 应用 |
| Metal | 命令提交显式可控，异步模型清晰；要自己管同步 | 性能敏感管线、自定义渲染与计算 |

## Quick Start

前置条件：一台支持 Metal 的 Mac，实验目录自带 `command_queue.sh` 脚本。

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

下面是本实验的全部关键代码，它在做的事：建一条队列、装一个缓冲、贴上标签、提交、等待完成。

```swift
let queue = device.makeCommandQueue()          // 提交通道：建一次用到底
let buffer = queue.makeCommandBuffer()         // 执行单元：每次任务一个
buffer.label = "MyFirstCommandBuffer"          // 调试标记：GPU 帧调试器里可见
buffer.commit()                                // 冻结并送入 GPU 时间线（异步）
buffer.waitUntilCompleted()                    // CPU 同步点：等到 GPU 干完
```

## How It Works

这节按缓冲的一生拆开看：创建 → 编码（本实验省略）→ `commit()` 提交 → `completed` 完成。

完整层次是 Device → CommandQueue → CommandBuffer → CommandEncoder → `commit()`。队列管排队，缓冲装命令，编码器（encoder，往缓冲里写具体指令的对象）负责填充绘制或计算指令。

本实验的缓冲是空的——连一个 encoder 都没创建，但 `commit()` 后 GPU 依然完整走了"排队 → 执行 → 完成"一趟。这说明空缓冲也是合法的 GPU 任务，机制本身已经跑通。

为什么 `commit()` 与 `completed` 之间 CPU 还能继续干活：`commit()` 只是把缓冲交给驱动排队，不等执行，CPU 立即返回。真正的等待发生在 `waitUntilCompleted()`——你在验证方法里看到的"`committed` 打印后程序没卡住"，就来自这个语义。

队列与缓冲的成本结构决定用法：队列绑定驱动资源且线程安全，创建昂贵，一个 App 通常只建一个、长期复用；缓冲是一次性容器，用完即弃，每次任务新建。`label` 属性（输出里的 `"MyFirstCommandBuffer"`）在 Xcode GPU 调试器里可见，多缓冲场景是排查利器。

## Pitfalls & Q&A

坑一：`commit()` 之后继续往缓冲里编码。
现象是后续编码不生效或直接报错。原因是 `commit()` 已把缓冲冻结，内容不可再改。解法：所有编码在 `commit()` 之前完成；要再提交，新建一个缓冲。

坑二：渲染循环里调用 `waitUntilCompleted()`。
现象是帧率上不去，CPU 大量时间在空等。原因是它是 CPU 阻塞等待，把本可并行的两条时间线拧回了一条。

解法：渲染场景用 drawable（可呈现的屏幕图像）与 CAMetalLayer（把渲染结果显示到屏幕的系统层）同步；计算场景在读取结果前才等待。

坑三：多缓冲场景在 GPU 调试器里分不清谁是谁。
原因是缓冲没有设置 `label`，默认无可读标识。解法：创建后立刻赋 `buffer.label = "..."`，命名从第一个缓冲就养成。

问：CPU 怎么知道 GPU 干完了？
两条路：`waitUntilCompleted()` 阻塞等待，或 `addCompletedHandler` 注册回调，GPU 完成时通知 CPU。渲染场景另有第三条：靠 `present(drawable)` 与 CAMetalLayer 的呈现节奏同步。
