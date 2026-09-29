# 01 · 获取 GPU 设备：Metal 世界的入口

> 本实验完成 GPU 编程的第一步：拿到代表本机 GPU 的设备对象，并读出它的能力上限。读完你将能获取 Metal（Apple 提供的 GPU 编程框架）的默认设备，看懂它的四类查询接口，并知道写代码前必须先确认哪些硬件上限。

## Background

在 Metal 出现之前，macOS 上的图形与 GPU 计算主要走 OpenGL 这类跨平台标准。那时程序想知道"这块 GPU 支持什么"，要靠两件事：读取一组全局常量上限（例如最大纹理尺寸），再解析一长串扩展名称字符串，逐个判断某个功能是否存在。

这种做法在真实项目里容易撞墙：同一份查询代码在不同厂商的 GPU 上可能返回不同结果，能力判断散落在代码各处，漏判一个扩展就在某些机器上崩溃。此外，OpenGL 为兼容各家硬件维护了一层较厚的通用抽象，难以直接暴露 Apple 芯片的特性。

Apple 在 2014 年发布了 Metal，一套贴着自家硬件设计的低开销 GPU API。它把"这块 GPU 是谁、支持什么、能创建什么"收敛到单个设备对象上来回答，后续所有 GPU 对象也都从这个对象创建。

## What

`MTLDevice` 是 Metal 中代表一块 GPU 硬件的对象，承担两个职责：能力查询的总入口（回答"这块 GPU 支持什么"），以及一切 GPU 对象的工厂（命令队列、缓冲区、渲染管线、纹理都由它创建）。

可以把 `MTLDevice` 想象成一台机器的"出厂规格书 + 订货窗口"：先翻规格书确认上限，再向订货窗口下订单创建对象。但和纸面规格书不同的是，这些上限是运行时才确定的事实，程序每次启动都应重新查询，而不是写死在代码里。

设备提供四类信息：

| 类别 | 属性 | 通俗理解 |
|:---|:---|:---|
| 基本信息 | `name`、`registryID` | GPU 叫什么、系统里注册的编号 |
| 计算能力 | `maxThreadsPerThreadgroup`、`maxThreadgroupMemoryLength` | 一个线程组（GPU 并行调度的基本单位）最多塞多少线程、共享内存多大 |
| 内存 | `hasUnifiedMemory`、`recommendedMaxWorkingSetSize`、`maxBufferLength` | 统一内存、建议工作集、单个缓冲上限 |
| 特性集 | `supportsFamily(_:)` | 支持哪些 GPU 家族（Apple 按芯片世代划分的支持等级，如 `.metal3`、`.apple7`） |

## When to Use

这节回答：什么时候需要认真查设备能力，什么时候拿起来直接用。

典型场景：

- 写 compute kernel（在 GPU 上并行执行的函数）之前：先查 `maxThreadsPerThreadgroup`，把线程配置放进安全范围。
- 分配大块数据之前：先查 `maxBufferLength` 与 `recommendedMaxWorkingSetSize`，决定数据是否需要分块。
- 按芯片世代启用特性：用 `supportsFamily(_:)` 判断设备支持哪个家族，旧芯片走降级代码路径。

何时不用：只是画一个三角形、用默认配置的程序，拿到默认设备直接用即可，不必盘问全部上限。能力查询做一次并缓存结果即可，不要放进每帧执行的热路径。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| CPU 计算 | 无 GPU 依赖、逻辑直观；数据量大或并行度高时慢 | 数据量小、分支逻辑多、并行度低的任务 |
| OpenGL / OpenGL ES | 跨平台老标准；在 Apple 平台已被标记废弃，难用上新特性 | 维护历史跨平台代码 |
| SpriteKit / SceneKit | 高层 2D/3D 场景框架，开箱即用；自定义渲染空间小 | 标准 2D 游戏、3D 展示，不想管渲染细节 |
| Metal | 直接控制 GPU 与资源，可写自定义 kernel；样板代码多 | 性能敏感管线、自定义并行计算与渲染 |

## Quick Start

前置条件：一台支持 Metal 的 Mac。实验目录自带 `gpu_info.sh`，负责构建、运行与清理。

```bash
./gpu_info.sh          # 一条龙：build → observe → clean
./gpu_info.sh observe  # 只运行（先 build 过）
```

真实输出（节选）：

```
╔══════════════════════════════════════════════════════════════╗
║              GPU DEVICE INFORMATION                         ║
╚══════════════════════════════════════════════════════════════╝
📱 BASIC DEVICE INFO
  Device Name:              Apple M5 Pro
🧵 THREAD & COMPUTE CAPABILITIES
  Max Threads Per Threadgroup:  1024 × 1024 × 1024
  Max Threadgroup Memory Length: 32768 bytes (~32 KB)
💾 MEMORY INFORMATION
  Has Unified Memory:       true
  Recommended Max Working Set Size: ~51.84 GB
```

验证方法：`Device Name` 应显示你的芯片型号；Apple Silicon 上 `Has Unified Memory` 必然是 `true`。

下面是本实验的核心代码，它在做的事：先拿到默认设备，再读出三组最常用的上限。

```swift
// 获取系统默认 GPU——整个 Metal 程序的第一行代码
guard let device = MTLCreateSystemDefaultDevice() else { return }

// 线程组上限（三维）：写 compute kernel 前必查，超了直接失败
let m = device.maxThreadsPerThreadgroup   // 本机 1024 × 1024 × 1024

// 统一内存与建议工作集：决定你能塞多少数据进 GPU
device.hasUnifiedMemory                   // Apple Silicon 恒为 true
device.recommendedMaxWorkingSetSize       // ~51.84 GB
```

## How It Works

这节拆开一次设备查询从发起到打印的完整链路，共四步：

1. 程序调用 `MTLCreateSystemDefaultDevice()`，向 Metal 框架要设备。
2. Metal 经驱动读取硬件属性（芯片型号、线程上限、内存布局）。
3. 框架把封装好的 `MTLDevice` 句柄（指向这块 GPU 的引用）交回程序。
4. 实验代码逐项读取属性，打印报告。

你在输出里看到的 `Max Threads Per Threadgroup: 1024 × 1024 × 1024`，就来自第 4 步读到的 `device.maxThreadsPerThreadgroup`。

为什么先查再写：线程组（threadgroup，GPU 并行调度的基本单位）的三维上限、缓冲区大小上限都是硬件契约。提前查清，就能在写内核时把配置放进安全范围，而不是等运行时报错。

统一内存（CPU 和 GPU 共享同一块物理内存）是 Apple Silicon 的底色。数据不必像独立显卡那样在 CPU 内存与显存之间经 PCIe 总线来回拷贝——这就是 Metal 里 `.storageModeShared`（共享模式）缓冲能被 CPU/GPU 双端直接访问的原因。

## Pitfalls & Q&A

坑一：`MTLCreateSystemDefaultDevice()` 结果未处理导致编译警告或运行崩溃。
现象是拿到空值还想继续用。原因是该调用返回 Optional（可能为空的值），模拟器或极老的机器上拿不到默认设备。解法：用 `guard let` 解包，失败时走降级路径。

坑二：调用 `supportsFeatureSet(_:)` 出现废弃（deprecated）警告。
原因是它按特性集合查询，属于历史遗留 API。解法：新代码改用 `supportsFamily(.metal3)`、`supportsFamily(.apple7)` 这类按芯片世代的查询。

坑三：某个设备属性在旧系统上编译或运行失败。
原因是属性随系统演进，旧系统上不存在。解法：属性外面包 `#available(macOS 10.15, *)` 这类版本守卫，这是生产代码的标准写法。

问：`recommendedMaxWorkingSetSize` 是硬上限吗？
不是。它是系统建议的工作集规模（程序常驻数据的量），规划数据时按它控制是安全做法；单个缓冲区的硬上限另看 `maxBufferLength`。

问：所有程序都要把设备能力查一遍吗？
不必。能力查询服务于"写内核前定配置"和"分大数据前定方案"这两类决策；默认配置的小程序拿到设备直接用即可，需要时再查。
