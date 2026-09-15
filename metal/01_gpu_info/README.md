# 01 · 获取 GPU 设备：Metal 世界的入口

> GPU 编程的第一步不是画任何东西，而是先搞清楚：机器上有没有 GPU、它是谁、它能干什么。
> Metal 把"GPU 硬件"抽象成 `MTLDevice`——后面所有对象（命令队列、缓冲区、管线、纹理）都由它创建。
> 本实验把这台 Mac 的 GPU 能力"盘个底朝天"，为整个系列摸清硬件底气。

## 1. 为什么需要它

`MTLDevice` 不是"一块显卡"的模型，而是**一组能力契约**：Metal 用它统一了不同芯片的差异，开发者只需要问"你支持什么"。写计算着色器时，超过 `maxThreadsPerThreadgroup` 会直接失败；分配缓冲超过 `maxBufferLength` 同样如此——这些上限只有先问过设备才知道。

> 拿到一个 `MTLDevice`，等于拿到了一把打开 GPU 世界的钥匙。

## 2. 总览：核心机制一图看懂

![MTLDevice 能力探测架构](images/gpu_info.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/metal/01_gpu_info/images/gpu_info.html)（或本地打开 [`images/gpu_info.html`](images/gpu_info.html)）。

一条主链路：程序向 Metal 框架要设备 → Metal 经驱动读取硬件属性 → `MTLDevice` 句柄交回程序 → 打印报告。一句话心智模型：**`MTLDevice` 是能力查询的总入口，也是一切 GPU 对象的工厂**。

## 3. 快速开始

```bash
./gpu_info.sh          # 一条龙：build → observe → clean
./gpu_info.sh observe  # 只运行（先 build 过）
```

真实输出（Apple M5 Pro 节选）：

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

## 4. 核心概念

### 4.1 设备提供四类信息

| 类别 | 属性 | 通俗理解 |
|:---|:---|:---|
| 基本信息 | `name`、`registryID` | GPU 叫什么、系统里注册的编号 |
| 计算能力 | `maxThreadsPerThreadgroup`、`maxThreadgroupMemoryLength` | 一个线程组最多塞多少线程、共享内存多大 |
| 内存 | `hasUnifiedMemory`、`recommendedMaxWorkingSetSize`、`maxBufferLength` | 统一内存、建议工作集、单个缓冲上限 |
| 特性集 | `supportsFamily(_:)` | 支持哪些 GPU 家族（`.metal3`、`.apple7`…） |

### 4.2 统一内存是 Apple Silicon 的底色

CPU 和 GPU 共享同一块物理内存，无需像独立显卡那样走 PCIe 拷贝。这就是后面所有实验里 `.storageModeShared` 缓冲能被 CPU/GPU 双端直接访问的原因。本机实测建议工作集约 51.84 GB——为光线追踪（路线图项目 21）和机器学习（阶段六）提供了硬件底气。

### 4.3 易错点

- `MTLCreateSystemDefaultDevice()` 返回 **Optional**：模拟器或极老机器上会拿不到，必须 `guard`。
- 新代码优先 `supportsFamily(.metal3)` 而不是老的 `supportsFeatureSet(_:)`（后者已废弃）。
- API 随系统演进，属性外面包 `#available(macOS 10.15, *)` 这类版本守卫是生产级标准写法。

## 5. 关键 API 与字段

```swift
// 获取系统默认 GPU——整个 Metal 程序的第一行代码
guard let device = MTLCreateSystemDefaultDevice() else { return }

// 线程组上限（三维）：写 compute kernel 前必查，超了直接失败
let m = device.maxThreadsPerThreadgroup   // 本机 1024 × 1024 × 1024

// 统一内存与建议工作集：决定你能塞多少数据进 GPU
device.hasUnifiedMemory                   // Apple Silicon 恒为 true
device.recommendedMaxWorkingSetSize       // ~51.84 GB
```

为什么先查再写：线程组上限、缓冲上限都是**硬件契约**，提前知道能在写内核时就把 `threads_per_threadgroup` 配置在安全范围内，而不是等运行时报错。

## 6. 文件结构

```
01_gpu_info/
├── README.md                       # 本文档
├── gpu_info.sh                     # 主演示脚本：build → observe → clean
├── main.swift                      # 入口包装：调用 runGPUInfo()
├── gpu_info.swift                  # 实验程序本体：9 区块逐项盘问设备
└── images/
    ├── gpu_info.architecture.json  # 图源（Typed JSON IR）
    ├── gpu_info.html               # 交互版架构图（浏览器打开）
    └── gpu_info.svg                # 双主题矢量版（README 内嵌）
```

## 7. 深入要点

- **`MTLDevice` 是什么？** GPU 硬件的能力契约 + 对象工厂；`MTLCreateSystemDefaultDevice()` 获取，所有队列/缓冲/管线/纹理都由它创建。
- **统一内存带来什么改变？** CPU/GPU 共享物理内存，`storageModeShared` 缓冲零拷贝双端访问；不再需要显式的 host→device 传输。
- **`maxThreadsPerThreadgroup` 为什么重要？** 它是线程组三维上限（本机 1024³），compute kernel 的 `threadsPerThreadgroup` 配置超过它会在创建管线/派发时报错。
- **`supportsFamily` vs `supportsFeatureSet`？** 前者按芯片世代（`.apple7`/`.metal3`），是现代 API；后者按特性集合，是历史遗留，新代码不要用。

## 8. 总结

本实验拿到了 `MTLDevice`——钥匙在手，但 GPU 还没"跑起来"：还缺一个把命令送进 GPU 的通道。下一篇创建第一个 `MTLCommandQueue` / `MTLCommandBuffer`，亲眼看到一条命令从提交到完成的全过程。

→ 下一篇：[02 · 第一个命令队列](../02_command_queue/README.md)
