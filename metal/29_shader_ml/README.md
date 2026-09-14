# 29 · Shader ML 突破：tensor kernel 全链路

> 路线图许诺的"着色器里跑张量计算"，本实验真跑通了：从 MSL tensor 语法、
> 编译链选择，到 MTL4 命令栈上的全链路派发与 CPU 验证。

## 1. 为什么需要它

Metal 4 的 MSL 引入了 tensor 类型。正确语法是什么、哪条编译链能编、GPU 上怎么派发、CPU 怎么验证——本实验用三轮递进实验把这些问题一次答清，全部结论来自真实编译器与 GPU 运行结果。

## 2. 总览：核心机制一图看懂

![Shader ML 数据流](images/shader_ml.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/29_shader_ml/images/shader_ml.html)（或本地打开 [`images/shader_ml.html`](images/shader_ml.html)）。

三轮递进：运行时编译 → 工具链编译 → MTL4 栈派发验证。一句话心智模型：**tensor 是绑在 buffer 槽上的 GPU 资源，普通 kernel 就能用**。

## 3. 快速开始

```bash
./shader_ml.sh               # 一条龙
```

真实输出：

```
第一轮（运行时 makeLibrary）：✅ 编译通过（前端已支持 tensor，可直接派发）
第二轮（Xcode metal CLI）：metal
✅ 第二轮：tensor kernel 编译通过 → metallib（dextents<int,1> + [[buffer(i)]] 语法）
✅ 第三轮：tensor 全链路验证通过——填充 → ×2 → 写回 buffer，1024 元素全对
          （p[0]=0.0 p[1]=2.0 p[1023]=2046.0）
```

验证方法：三段 kernel 串联（填充张量 → 张量×2 → 张量写回普通 buffer），CPU 读回逐元素断言。

## 4. 核心概念

### 4.1 正确的 tensor 语法（2026-09 实测）

```metal
#include <metal_tensor>
using namespace metal;

kernel void double_tensor(tensor<device float, dextents<int, 1>> in  [[buffer(0)]],
                          tensor<device float, dextents<int, 1>> out [[buffer(1)]],
                          uint i [[thread_position_in_grid]]) {
    out[i] = in[i] * 2.0;
}
```

关键点：模板参数用 `dextents<int, R>`（动态维度），绑定用 `[[buffer(i)]]`（buffer 槽）。
错误写法 `extents<uint, N>, tensor_handle, tensor_offset` + `[[binding(i)]]` 会报
"invalid type … for input declaration"。

### 4.2 三轮实验的结论

第一轮：运行时 `makeLibrary(source:)` **能编译**正确语法的 tensor kernel（旧版实验的失败是语法错误，不是前端缺失）。
第二轮：Xcode 26 工具链 `metal` CLI 同样可编译并打包成 `.metallib`。
第三轮：MTL4 命令栈全链路派发验证通过——tensor 与普通 buffer 在同一参数表里混绑。

### 4.3 MTL4 栈上的张量绑定

`argTable.setResource(tensor.gpuResourceID, bufferIndex:)` 把 MTLTensor 绑进 buffer 槽，
与 `setAddress(buffer.gpuAddress, index:)` 的普通 buffer 绑定可混用。

### 4.4 数据进出的搬运模式

`MTLTensor.buffer == nil`（无 CPU 指针），CPU 无法直接读写张量。
模式：kernel 写入张量（fill）→ kernel 计算 → kernel 搬回普通 buffer（tensor_to_buffer）→ CPU 验证。

## 5. 关键代码

```swift
// 张量绑进 buffer 槽（与普通 buffer 的 setAddress 混用）
dispatch(pDouble, [(tIn.gpuResourceID, 0), (tOut.gpuResourceID, 1)], [])
dispatch(pToBuf,  [(tOut.gpuResourceID, 0)], [(bufA.gpuAddress, 1)])
```

## 6. 文件结构

```
29_shader_ml/
├── README.md                  # 本文档
├── shader_ml.sh               # 主演示脚本
├── main.swift                 # 入口包装：调 runShaderMl()
├── shader_ml.swift            # 实验程序：三轮编译/派发/验证
└── images/                    # 图三件套
```

## 7. 深入要点

- **tensor 参数能在普通 kernel 入口用吗？** 能——`dextents` + `[[buffer]]` 语法下不需要 ML 专用编译路径。
- **张量怎么绑？** `gpuResourceID` 进参数表的 buffer 槽；MTL4 的 `setResource(_:bufferIndex:)`。
- **CPU 怎么拿结果？** MTLTensor 无 CPU 指针，用 kernel 搬回普通 buffer 再读。
- **真正的边界在哪？** ML Command Encoder 的 ML pipeline 仍需 Core ML GPU 特化二进制，命令行编译链不产出（见实验 24）；而手写 tensor shader 不受此限。

## 8. 总结

从"可行探测"升级为"真跑通"：语法、编译链、绑定、派发、验证全链闭环。下一篇把 tensor/ML 能力放回渲染管线，做 ML+图形混合管线。

→ 下一篇：[30 · ML+图形混合管线](../30_ml_graphics/README.md)
