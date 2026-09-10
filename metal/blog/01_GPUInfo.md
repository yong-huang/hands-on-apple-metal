# ⚡️ Metal 项目 1：Hello World — 获取 GPU 设备（01_GPUInfo.swift）

> 所属系列：《Apple Metal 30 小项目学习清单》第一阶段「Metal 基础入门」（项目 1/30）
> 代码：`0x_learn_metal/LearnMetal/LearnMetal/Programs/01_GPUInfo.swift`
> 目标：认识 `MTLDevice`，把当前 Mac 的 GPU 能力"盘个底朝天"。

---

## 一、为什么第一个项目是"问设备"

GPU 编程的第一步不是画任何东西，而是先搞清楚：**机器上有没有 GPU、它是谁、它能干什么**。

Metal 用 `MTLDevice` 来抽象"GPU 硬件设备"。它是整个 Metal 世界的入口——后面所有对象（命令队列、缓冲区、管线、纹理）都是由它创建的。所以：

> 拿到一个 `MTLDevice`，等于拿到了一把打开 GPU 世界的钥匙。

```swift
guard let device = MTLCreateSystemDefaultDevice() else {
    print("Failed to get default Metal device")
    return
}
print("Device Name: \(device.name)")
```

`MTLCreateSystemDefaultDevice()` 返回系统默认的 GPU。如果是 Apple Silicon（M1/M2/M3/M4/M5），几乎必然成功。本机实测拿到的是 **Apple M5 Pro**。

---

## 二、领域知识：`MTLDevice` 是什么

`MTLDevice` 不是"一块显卡"的模型，而是**一组能力契约**。Metal 用它统一了集成 GPU 与独立 GPU 的差异，开发者只需要问"你支持什么"，而不必关心具体芯片型号。

它主要提供四类信息：

| 类别 | 属性 | 通俗理解 |
|:---|:---|:---|
| 基本信息 | `name`、`registryID` | GPU 叫什么、系统里注册的编号 |
| 计算能力 | `maxThreadsPerThreadgroup`、`maxThreadgroupMemoryLength` | 一个线程组最多塞多少线程、共享内存多大 |
| 内存 | `hasUnifiedMemory`、`recommendedMaxWorkingSetSize`、`maxBufferLength` | 是否统一内存（Apple Silicon 都是）、建议工作集、单个缓冲上限 |
| 特性集 | `supportsFamily(_:)`、`supportsFeatureSet(_:)`、纹理格式 | 支持哪些 GPU 家族/特性/像素格式 |

**苹果芯片的统一内存（Unified Memory）**是理解这张图的关键：CPU 和 GPU 共享同一块物理内存，无需像传统独立显卡那样通过 PCIe 传输数据。这也是 Metal 缓冲默认就能被 CPU/GPU 双端访问的重要原因。

---

## 三、代码架构

`01_GPUInfo.swift` 以 `runGPUInfo()` 为核心，按 9 个区块有节奏地"盘问"设备：

```
runGPUInfo()
├── 1. 基本信息    device.name / registryID
├── 2. 计算能力    maxThreadsPerThreadgroup（宽/高/深）
├── 3. 内存        hasUnifiedMemory / recommendedMaxWorkingSetSize / maxBufferLength
├── 4. 设备属性    isLowPower / isHeadless / isRemovable
├── 5. GPU 家族    supportsFamily(.metal3 / .common1/2/3 / .mac1/2 ...)
├── 6. 特性集      曲面细分 / 读写纹理 / 可编程混合 / 光线追踪
├── 7. 纹理格式    rgba8Unorm / rgba16Float / depth32Float ... 逐一探测
├── 8. 附加信息    是否有显示输出 / 高性能 or 低功耗 / 内建 or eGPU
└── 9. 性能指标    currentAllocatedSize / maxThreadgroupMemoryLength
```

几个可以照抄的**探测姿势**：

```swift
// 线程组上限（三维）
let maxThreads = device.maxThreadsPerThreadgroup
print(maxThreads.width, maxThreads.height, maxThreads.depth)

// 是否支持某个 GPU 家族（Metal 3 / Apple Silicon Common 系列）
if #available(macOS 10.15, iOS 13.0, *) {
    device.supportsFamily(.metal3)
}

// 是否统一内存、建议最大工作集
if #available(macOS 10.15, iOS 13.0, *) {
    device.hasUnifiedMemory
    device.recommendedMaxWorkingSetSize
}
```

注意代码里大量使用 `#available` 和 `#if os(macOS)` 做**版本与平台守卫**——Metal 的 API 随着系统版本不断演进（如 `.metal3` 需要 macOS 10.15+），这套守卫是生产级代码的标准写法。

---

## 四、本机实测结果（Apple M5 Pro 节选）

```
Device Name:              Apple M5 Pro
Max Threads Per Threadgroup: 1024 × 1024 × 1024
Max Threadgroup Memory Length: 32768 bytes (~32 KB)
Has Unified Memory:       true
Recommended Max Working Set Size: ~51.84 GB
Metal 3: ✅  Common 1/2/3: ✅  Mac 1/2: ✅
Tessellation ✅  Read-Write Textures ✅  Raytracing ✅
rgba8Unorm ✅  rgba32Float ✅  depth32Float ✅
```

看到**统一内存 51.84 GB、支持光线追踪**，意味着之后的光线追踪（路线图项目 21）和机器学习（阶段六）都有硬件底气。

---

## 五、运行方式

在 Xcode 中打开 `LearnMetal.xcodeproj`，确认 `main.swift` 解注释并调用对应入口：

```swift
print("=== Running GPU Info ===")
runGPUInfo()
```

命令行运行同一模块内的 `runGPUInfo()` 即可，输出一份带图标的彩蛋版设备报告。

---

## 六、延伸思考

- **为什么关心 `maxThreadsPerThreadgroup`？** 写计算着色器（项目 12 起的 core）时，超过线程组上限直接编译/运行失败，提前知道上限能避免踩坑。
- **`supportsFamily` vs `supportsFeatureSet`**：前者是现代 API（按芯片世代分），后者是历史遗留（按特性集合分）。新代码优先用 `supportsFamily`。
- 下一个项目就要用到 `device` 了——由它创建命令队列，把 GPU 真正"跑起来"。

---

*系列：《Apple Metal 30 小项目》· 第一阶段：基础入门（1-5）→ 项目 2：创建命令队列*