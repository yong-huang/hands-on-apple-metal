# 23 · 帧捕获：MTLCaptureManager 程序化调试
> GPU 出了问题只能靠猜吗？Metal 能把一段时间内 GPU 执行的每条命令录成文件。本实验不开 Xcode 界面、不点按钮，用几行 API 把 3 个计算 pass（一趟完整的计算任务）捕获成 .gputrace 文件（Xcode 的 GPU 跟踪文档）。读完本篇你能给任意 Metal 程序加一个可自动化的 GPU 录制开关，并知道录下的文件怎么用。

## Background

GPU 程序出错时，传统手段相当有限：CPU 侧能打印日志、下断点，但那只能看到"命令提交了没有"；命令进了 GPU 之后就是黑盒——kernel（GPU 上并行执行的函数）跑了多久、缓冲内容对不对，CPU 一概不知。

手动捕获是官方给出的交互式答案：在 Xcode 里启动程序、点捕获按钮，就能看到一帧的逐命令时间线。但这条路线依赖 Xcode 会话：不能在自动化脚本里做，不能无人值守地跑，更没法成为回归（改动后自动重跑验证的流程）的一环。

程序化捕获因此出现：苹果提供 MTLCaptureManager，允许在代码里指定捕获对象与窗口期，把期间提交的所有命令录成 .gputrace 文件，离线用 Xcode 打开分析。录制由此可以从"人点按钮"变成"脚本里的一步"。

## What

帧捕获（GPU capture）是给 GPU 时间线开"行车记录仪"：把一段窗口期内提交到 GPU 的所有命令录成文档。

本实验用 Metal 的 MTLCaptureManager——纯代码、不开 Xcode——把 3 个"数组翻倍"计算 pass 录成 demo_capture.gputrace，同时用回读断言确认计算正确。

一句话心智模型：**捕获 = 给 GPU 时间线开行车记录仪**。可以把 startCapture 到 stopCapture 之间想象成行车记录仪的录制窗口：窗口内提交的每条命令都被记录。但和行车记录仪不同的是：录制有运行时开销，GPU 要边执行边记录，所以窗口必须小而准，不能常开。

本实验的被录负载：1024 个元素的数组，3 个 pass 串联、每个翻一倍（×2×2×2 = ×8）；相邻 pass 用 ping-pong 双缓冲（两块缓冲轮流读写）衔接，避免读写撞在同一块内存上。

## When to Use

这一节给判断力：什么时候需要"录 GPU"，什么时候是杀鸡用牛刀。

典型场景：

- GPU 表现不符合预期——结果错、画面错、性能差——需要逐命令查看时间线、参数与缓冲内容时。
- 自动化回归：把捕获嵌进测试脚本，每次改动都留一份 GPU 执行存档，配合数值断言形成双回归。
- 性能存档：记录某个版本 kernel 的执行耗时，供前后版本对比。

何时不用：

- 只需要 CPU 侧信息（Swift 逻辑对不对、命令有没有提交）：断点和日志更轻。
- 想常驻开启：捕获有运行时开销，只开需要诊断的窗口期。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| 打印日志 / 断点 | 只见 CPU 侧，GPU 执行明细是黑盒 | 查 Swift 逻辑、确认命令提交了 |
| Xcode 手动捕获 | 交互式、所见即所得；依赖 Xcode 会话启动程序 | 调试单个问题帧，人在现场 |
| MTLCaptureManager 程序化捕获（本实验） | 代码里精确开窗，可嵌入脚本与自动化 | 无人值守录制、回归测试、性能存档 |

## Quick Start

前置条件：macOS 加 Xcode 的 Swift 工具链；捕获层开关 `METAL_CAPTURE_ENABLED=1` 必须生效（脚本已内置，缺了它会直接抛错，原因见 Pitfalls）。在 `metal/23_gpu_capture/` 目录下运行：

```bash
./gpu_capture.sh               # 一条龙（脚本已内置捕获层开关）
```

真实输出：

```
…（前略：程序标题、设备名、捕获支持自检共三行）
▶️ 捕获开始（目标: 命令队列）
  pass 1: out[1]=2（应为 2）
  pass 2: out[1]=4（应为 4）
  pass 3: out[1]=8（应为 8）
⏹️ 捕获结束
✅ 计算验证通过：1024 个元素 ×8 全部正确
✅ 捕获文件已生成: demo_capture.gputrace（384 字节）
…（后略：用 Xcode 打开文件的提示一行）
```

验证方法：三个 pass 串联翻倍（ping-pong 缓冲防读写别名），×8 全对 + 文件落盘，双回归通过。落盘的 demo_capture.gputrace 用 Xcode 打开（File → Open），可逐条查看 3 个 pass 的命令、耗时与缓冲内容。

捕获的配置代码在 `gpu_capture.swift` 里：

```swift
let desc = MTLCaptureDescriptor()
desc.captureObject = commandQueue          // 捕获整个队列
desc.destination = .gpuTraceDocument
desc.outputURL = URL(fileURLWithPath: "demo_capture.gputrace")
try manager.startCapture(with: desc)
// ... 提交工作负载 ...
manager.stopCapture()
```

这段在做什么：描述一次捕获——对象是命令队列（GPU 命令的提交通道，队列级捕获把期间提交的所有命令一网打尽），目的地是 .gputrace 文件；startCapture 与 stopCapture 之间提交的工作负载就是被录制的窗口。

## How It Works

按一次捕获的生命周期展开：环境自检 → 配置与开窗 → 被录负载 → 落盘验证。

**环境自检。** 程序启动先打印 `supportsDestination(.gpuTraceDocument)` 的返回值。未注入捕获层时它返回 false——这个调用是环境自检的探针：false 就不必往下走，直接修环境。

**配置与开窗。** `MTLCaptureDescriptor` 指定两件事：捕获对象（可以是命令队列、设备或 MTKView——MetalKit 的视图类，本实验用命令队列）与目的地（`.gpuTraceDocument` 文件）。程序先删除同名的旧文件再开录，避免新旧混淆。

**被录负载。** 窗口期内提交 3 个"翻倍" pass。核心难点是缓冲编排：三个 pass 串联（×2×2×2 = ×8），若读写同一块缓冲，读和写会指向同一内存（别名问题，顺序错了就读到脏数据）。

解法是 ping-pong 双缓冲：从 A 读、往 B 写，交换后下一趟从 B 读、往 A 写——每 pass 一个方向，语义清晰：

```swift
var src = bufA, dst = bufB
for pass in 1...3 {
    demo.encodePass(input: src, output: dst, count: count)
    let p = dst.contents().bindMemory(to: Float.self, capacity: count)
    print("  pass \(pass): out[1]=\(String(format: "%.0f", p[1]))（应为 \(Int(pow(2, Double(pass))))）")
    (src, dst) = (dst, src)
}
```

为什么这样写：`src`/`dst` 两个变量每趟交换（`(src, dst) = (dst, src)`）——上一趟的输出就是下一趟的输入；每个 pass 结束后立即回读 1 个元素，打印"实际值（应为期望值）"，这就是真实输出里三行 pass 记录的来源。

**落盘验证。** stopCapture 之后做两件事：回读全部 1024 个元素断言 ×8 全对；检查文件存在且大小大于 0。你在真实输出里看到的三行 pass 结果、一行 ✅ 验证、一行文件落盘，分别对应这两层验证和中间的逐 pass 回读。

## Pitfalls & Q&A

**startCapture 抛 "Capture layer is not inserted"。** 现象：程序在 startCapture 处直接报错退出。原因：捕获层以动态库（运行时加载进进程的代码库）形式注入；Xcode 启动程序时会自动注入，命令行启动的进程默认没有。解法：启动前设置环境变量：

```bash
METAL_CAPTURE_ENABLED=1 ./gpu_capture
```

本实验的脚本已把这个开关固化——这也是本实验最重要的可迁移知识。

**计算验证通过，但捕获文件没生成。** 现象：打印"❌ 捕获文件未生成（检查磁盘权限）"。原因：输出路径不可写，或捕获窗口内没有提交任何命令。解法：确认当前目录可写；确认 startCapture 与 stopCapture 之间确实提交了命令缓冲。

**gputrace 里能看到什么？** 逐命令时间线、kernel 参数、缓冲内容、API 调用栈——相当于 GPU 侧的"断点 + 性能表"：命令有没有按预期顺序提交、每个 pass 花了多久、缓冲在命令前后是什么值，都能对着看。

**捕获窗口怎么定？** startCapture 到 stopCapture 之间就是窗口。窗口越大，录制开销越大、文件也越大，所以只圈住需要诊断的那几个 pass——程序化 API 的价值正在于能把窗口切得足够小、足够准，这是手动点按钮做不到的。
