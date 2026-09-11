# 23 · 帧捕获：MTLCaptureManager 程序化调试

> GPU 出了问题只能靠猜？Metal 可以把一帧的执行明细完整"录"下来。
> 本实验不开 Xcode、不点按钮，用三行 API 把 3 个计算 pass 捕获成 .gputrace 文件，
> 并诚实记录命令行环境最大的那个坑。

## 1. 为什么需要它

GPU 调试的信息缺口巨大：命令提交了吗？kernel 跑了多久？缓冲内容对不对？`.gputrace` 是官方答案——逐命令的时间线 + 参数 + 资源状态。程序化捕获让"录制"成为自动化回归的一环。

## 2. 总览：核心机制一图看懂

![帧捕获数据流](images/gpu_capture.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/23_gpu_capture/images/gpu_capture.html)（或本地打开 [`images/gpu_capture.html`](images/gpu_capture.html)）。

计算负载被捕获器录成 gputrace 文件，供 Xcode 离线分析；同场进行正确性双回归。一句话心智模型：**捕获 = 给 GPU 时间线开行车记录仪**。

## 3. 快速开始

```bash
./gpu_capture.sh               # 一条龙（脚本已内置捕获层开关）
```

真实输出：

```
▶️ 捕获开始（目标: 命令队列）
  pass 1: out[1]=2（应为 2）
  pass 2: out[1]=4（应为 4）
  pass 3: out[1]=8（应为 8）
⏹️ 捕获结束
✅ 计算验证通过：1024 个元素 ×8 全部正确
✅ 捕获文件已生成: demo_capture.gputrace（384 字节）
```

验证方法：三个 pass 串联翻倍（ping-pong 缓冲防读写别名），×8 全对 + 文件落盘，双回归通过。

## 4. 核心概念

### 4.1 最大的坑：捕获层注入

命令行（非 Xcode）启动的进程默认**没有捕获层**，`startCapture` 直接抛 "Capture layer is not inserted"。解法是启动前设置环境变量：

```bash
METAL_CAPTURE_ENABLED=1 ./gpu_capture
```

脚本已把开关固化——这是本实验最重要的可迁移知识。

### 4.2 捕获对象与输出

`MTLCaptureDescriptor` 指定捕获对象（命令队列/设备/MTKView）与目的地（`.gpuTraceDocument` 文件）。队列级捕获把期间提交的所有命令一网打尽。

### 4.3 ping-pong 缓冲

三个"翻倍"pass 要串联（×2×2×2=×8），读写同一缓冲是别名隐患——用 A→B→A→B 双缓冲轮转，位置语义清晰。

### 4.4 易错点

- `supportsDestination(.gpuTraceDocument)` 未注入时返回 false——它是环境自检的探针。
- 捕获有运行时开销：只捕获需要诊断的窗口期。

## 5. 关键 API 与字段

```swift
let desc = MTLCaptureDescriptor()
desc.captureObject = commandQueue          // 捕获整个队列
desc.destination = .gpuTraceDocument
desc.outputURL = URL(fileURLWithPath: "demo_capture.gputrace")
try manager.startCapture(with: desc)
// ... 提交工作负载 ...
manager.stopCapture()
```

## 6. 文件结构

```
23_gpu_capture/
├── README.md                     # 本文档
├── gpu_capture.sh                # 主演示脚本（内置 METAL_CAPTURE_ENABLED=1）
├── main.swift                    # 入口包装：调 runGpuCapture()
├── gpu_capture.swift             # 实验程序：负载 + 捕获 + 双回归
└── images/
    ├── gpu_capture.dataflow.json # 图源
    ├── gpu_capture.html          # 交互版
    └── gpu_capture.svg           # 双主题矢量版
```

## 7. 深入要点

- **gputrace 里能看到什么？** 逐命令时间线、kernel 参数、缓冲内容、API 调用栈——GPU 侧的"断点+性能表"。
- **程序化捕获与 Xcode 手动捕获的区别？** 前者可嵌入自动化回归、按需开窗；后者交互式但依赖 Xcode 会话。
- **为什么需要 METAL_CAPTURE_ENABLED？** 捕获层以动态库形式注入进程；Xcode 启动时自动注入，命令行需要显式开关。
- **捕获会影响性能吗？** 会。录制的窗口要小而准——这也是程序化 API 的价值。

## 8. 总结

GPU 有了行车记录仪。下一篇回到几何管线：从文本文件加载一个真正的 3D 模型。

→ 下一篇：[24 · OBJ 模型](../24_obj_model/README.md)
