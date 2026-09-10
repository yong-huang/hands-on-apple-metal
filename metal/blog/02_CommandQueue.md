# ⚡️ Metal 项目 2：创建第一个命令队列（02_CommandQueue.swift）

> 所属系列：《Apple Metal 30 小项目学习清单》第一阶段「Metal 基础入门」（项目 2/30）
> 代码：`0x_learn_metal/LearnMetal/LearnMetal/Programs/02_CommandQueue.swift`
> 目标：理解 `MTLCommandQueue` / `MTLCommandBuffer`，跑通"提交-执行-完成"的最小闭环。

---

## 一、核心领域知识：Metal 的三层执行骨架

GPU 不会"直接看到"你的图形数据，它只消费一种东西：**命令（Command）**。Metal 用三层对象组织这些命令，本项目的注释画出了完整结构：

```
MTLDevice         ① 硬件抽象层：GPU 的"化身"
   └─ MTLCommandQueue      ② 命令工厂："生产流水线"
         └─ MTLCommandBuffer   ③ 执行单元：一批命令的容器
```

### 1. `MTLCommandQueue` —— 命令队列（生产线）

- 由 `device.makeCommandQueue()` 创建，是**生成命令缓冲区**的工厂
- 内部维护 GPU 任务队列，**线程安全**，多个线程可并发提交缓冲区
- 每个队列可以同时存在多个缓冲

### 2. `MTLCommandBuffer` —— 命令缓冲区（集装箱）

- 装着实际要执行的指令（绘制调用、计算任务、拷贝……）
- 生命周期：`makeCommandBuffer()` → 往里编码命令 → `commit()` 提交 → GPU 异步执行 → `waitUntilCompleted()` 等它干完

**CPU 与 GPU 是异步的**：`commit()` 只把命令扔进 GPU 队列就立刻返回，CPU 可以继续干别的；只有显式调用 `waitUntilCompleted()`，CPU 才阻塞在这里等 GPU 收工。

---

## 二、代码架构（整段最小演示）

`runCommandQueue()` 只有 60 行，把骨架走了一遍：

```swift
guard let device = MTLCreateSystemDefaultDevice() else { ... }

// ① 创建命令队列
guard let commandQueue = device.makeCommandQueue() else { ... }

// ② 从队列取出一个命令缓冲
guard let commandBuffer = commandQueue.makeCommandBuffer() else { ... }
commandBuffer.label = "MyFirstCommandBuffer"

// ③ 提交（异步）
commandBuffer.commit()

// ④ 等待 GPU 完成（阻塞）
commandBuffer.waitUntilCompleted()
```

标准输出轨迹：

```
GPU Device: Apple M5 Pro
Command Queue created
Command Buffer: MyFirstCommandBuffer
Command Buffer committed
Command Buffer completed
```

顺序对应的就是 CPU 视角的生命周期：**创建 → 提交 → 完成**。

注意此时缓冲里**没有任何命令**（连一个 encoder 都没创建），但它依然是一个合法可提交的空缓冲——这正好证明：提交空缓冲也是 GPU 任务，整个"排队-执行"机制已经跑通。

---

## 三、与项目 1 的连接

项目 1 里拿到的 `MTLDevice`，在这里第一次派上用场：

```
项目1:  device = MTLCreateSystemDefaultDevice()   // 问"GPU 是谁"
项目2:  queue  = device.makeCommandQueue()         // 问"谁来干活"
项目3:  buffer = queue.makeCommandBuffer()         // 问"活装在哪"
```

每一层都由上一层创建，形成一棵清晰的依赖树。这张树形图会贯穿整个 Metal 学习：后续的 `MTLRenderCommandEncoder`（渲染编码器，项目 3 的主角）也是从命令缓冲里 `makeRenderCommandEncoder()` 出来的。

---

## 四、运行方式

```swift
// main.swift
print("=== Running Command Queue ===")
runCommandQueue()
```

跑完看到四行状态输出、进程正常退出且无崩溃，即满足路线图验收标准。

---

## 五、延伸思考

- **为什么这里要 `waitUntilCompleted`？** 演示程序想立刻看到"完成"状态。真实渲染中（项目 3 开始）通常用 `present(drawable)` + `commit()` 交给 Metal 管理，靠 swapchain 同步而不是手动等。
- **"线程安全"意味着什么？** 多个 CPU 线程可以同时从同一个队列拿缓冲、往 GPU 塞活，排序由 GPU 调度保证，这在后面做多线程渲染时很关键。
- 项目 3 的 `draw(in:)` 会复用这套骨架：拿设备→建队列→取缓冲→**编码绘制**→提交。骨架没变，变的只是中间"往缓冲里塞命令"的部分。

---

*系列：《Apple Metal 30 小项目》· 第一阶段：基础入门（1-5）→ 项目 3：渲染一个三角形*