# 25 · Shader ML 可行性探测

> 路线图许诺的"着色器里跑神经网络"，在真机上到底走到了哪一步？
> 本实验不吹不黑：真实触发一次 tensor 模板内核的编译，
> 把诊断原样呈现，把缺口精确到唯一的一环。

## 1. 为什么需要它

面对新 API，最贵的错误是"想当然"。本实验做两轮真实编译探测（运行时 makeLibrary 与 Xcode 工具链 metal CLI），用编译器诊断把就绪度与卡点定位到唯一一环——换一台机器跑一遍即可复用。

## 2. 总览：核心机制一图看懂

![Shader ML 探测数据流](images/shader_ml.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/25_shader_ml/images/shader_ml.html)（或本地打开 [`images/shader_ml.html`](images/shader_ml.html)）。

tensor 模板内核喂给运行时编译器，诊断如实输出，四步走通路径定位唯一卡点。一句话心智模型：**探测即结论，诊断即证据**。

## 3. 快速开始

```bash
./shader_ml.sh               # 一条龙
```

真实输出：

```
探测目标：MSL tensor 模板参数内核（Shader ML 的最小形态）
❌ 编译失败（预期内的失败，诊断如下）:
   program_source:3:41: error: template argument for template type parameter must be a type
—— 原因：tensor 模板由 ML 专用着色器编译器处理，运行时 makeLibrary 不包含该前端。
📌 走通 Shader ML 的完整路径：
   1. macOS 26.5 + Apple Silicon        → ✅ 已满足
   2. MTLTensor 数据面（实验 23）        → ✅ 已满足
   3. tensor 模板内核的 ML 编译链        → ❌ 需 Xcode 26 构建系统
   4. ML Command Encoder 派发（实验 24） → ✅ 编码器可用，等第 3 步
```

验证方法：失败诊断逐字来自编译器（非硬编码文案）；四步清单里三绿一红，卡点唯一。

## 4. 核心概念

### 4.1 Shader ML 的目标形态

MSL 直接以 `tensor<T, access>` 为内核参数，着色器内调用网络——数据不用离开 GPU 时间线。语法上它仍是 MSL，但需要 ML 专用的编译前端。

### 4.2 两轮探测的结论（2026-09 实测）

第一轮：运行时 `makeLibrary` 报 "unknown type tensor"——通用前端不含 tensor 模块。
第二轮：Xcode 26 工具链的 `metal` CLI **包含 `metal/metal_tensor` 模块**，`tensor<device float, extents<uint,N>, tensor_handle, tensor_offset>` 可以编译到"类型合法"，卡点收窄为最后一步：tensor 参数的 kernel 入口声明被拒（"invalid type … for input declaration"）——入口语法由 ML 专用编译路径定义，公开文档暂缺这段。
另：Core ML 模型制作链已验证可用（coremltools 9.0，`~/.venvs/ml`，.mlpackage 保存/加载通过）。

### 4.3 探测脚本的设计

尝试编译 → 捕获诊断 → 输出结构化结论。失败不是异常路径，而是**预期路径之一**——前提是失败被真实触发并如实呈现。

## 5. 关键代码

```swift
do {
    let lib = try device.makeLibrary(source: tensorKernelSource, options: nil)
    print("✅ 运行时编译器支持 tensor 语法")
} catch {
    let msg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String
    print("❌ 编译失败（预期内）:", msg?.prefix(300) ?? "")
}
```

## 6. 文件结构

```
29_shader_ml/
├── README.md                  # 本文档
├── shader_ml.sh               # 主演示脚本
├── main.swift                 # 入口包装：调 runShaderMl()
├── shader_ml.swift            # 实验程序：探测 + 诊断 + 路径结论
└── images/
    ├── shader_ml.dataflow.json# 图源
    ├── shader_ml.html         # 交互版
    └── shader_ml.svg          # 双主题矢量版
```

## 7. 深入要点

- **Shader ML 是什么？** Metal 4 允许 MSL 内核以 tensor 为参数、着色器内推理——推理与渲染共享 GPU 时间线。
- **运行时编译器与 metal CLI 的差别？** 前者不含 tensor 前端；后者含 metal_tensor 模块、能把类型编到合法，最后一步卡在入口声明语法。
- **如何向团队汇报"能不能用"？** 用可复现的探测脚本 + 诊断证据 + 卡点清单，而不是"应该可以/还不行"。

## 8. 总结

诚实边界画清：三步已就绪、一步待工具链。下一篇绕开缺口，用 MTL4 + 事件把"ML+图形混合管线"的同步骨架真跑起来。

→ 下一篇：[30 · ML+图形混合管线](../26_ml_graphics/README.md)
