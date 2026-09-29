# 29 · Shader ML 突破：tensor kernel 全链路

> Shader ML 指在着色器语言里直接使用 Metal 4 新增的 tensor 类型做计算。读完本篇你能拿到一套实测可用的 tensor 语法、弄清哪条编译链能编，并在 MTL4 命令栈上跑通"填充 → 计算 → 搬回 → CPU 验证"的全链路——全部结论来自真实编译器与 GPU 运行结果（2026-09 实测）。

## Background

Metal 4 的 MSL（Metal Shading Language，编写 Metal 着色器——在 GPU 上执行的绘图/计算小程序——的类 C++ 语言）引入了 tensor（张量，自带维度信息的 N 维数组）类型。在此之前，想在 GPU 上做自定义的多维计算只有两条路。

一条是把多维数据压平进一维 buffer（一段指定长度的连续内存），维度语义靠手算偏移维护——行、列、通道的换算全写在算术里，写错就读错数据。

另一条是走高层框架（MPS、Core ML）：调用现成算子（一个具体的计算单元，如矩阵乘、卷积）或打包完整模型，但算子库里没有的自定义计算就做不了，"在着色器里手写一个张量算子"缺少语言层支持。

tensor 类型给了第三条路：着色器参数可以直接声明为张量。但"类型存在"不等于"能用"——正确语法是什么、哪条编译链能编、GPU 上怎么派发、CPU 怎么验证，四个问题缺一个都跑不通。本实验用三轮递进把它们一次答清。

## What

Shader ML 在本实验中的具体形态是：一个普通计算内核（kernel，GPU 上大规模并行执行的小程序），参数直接用 MSL 的 tensor 类型声明，编译后经 MTL4 命令栈派发执行。一句话心智模型：**tensor 是绑在 buffer 槽上的 GPU 资源，普通 kernel 就能用**。

可以把 tensor 参数想象成"自带说明书的 buffer"——对 kernel 来说多了一张维度卡片，其余用法照旧。但和普通 buffer 不同的是，它采用 private 分配（GPU 独享、CPU 无法直接读写，lab 27 实测），数据进出 CPU 必须靠 kernel 搬运，不能直接读写。

## When to Use

- 手写自定义神经网络算子时：框架算子库没有的计算，用 tensor 语法直接写 kernel。
- 图形与张量计算要混合时：同一个 kernel 里既能访问纹理、顶点数据，也能访问张量。
- 小规模张量运算想绕开模型打包流程时：不必经过 Core ML 的模型编译，着色器层直接写。

何时不用：

- 跑现成的完整网络：走 Core ML / ML Command Encoder 路径更合适。
- 数据是纯一维、维度语义无用武之地：普通 buffer kernel 更简单。
- CPU 需要频繁直接读写数据：tensor 无 CPU 指针，用 buffer 少一道搬运。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| 普通 buffer kernel | 一维指针，维度自己管 | 一维或简单并行计算 |
| Shader ML tensor kernel（本文） | 着色器内建张量类型，手写算子自由 | 自定义算子、图形与张量混合 |
| ML Command Encoder + Core ML | 派发完整网络，需 GPU 特化二进制 | 推理现成模型（缺口见 lab 28） |
| MPS（Metal Performance Shaders） | Apple 的现成高性能算子库 | 常见算子直接调用，不自己写 |

## Quick Start

前置条件：macOS + Xcode 26 及以上（第二轮要用工具链的 metal 命令行编译器）。进入本目录运行：

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

MTL4 栈上张量与普通 buffer 混绑到参数表（ArgumentTable，预建的资源地址表，见 lab 28）的核心代码：

```swift
// 张量绑进 buffer 槽（与普通 buffer 的 setAddress 混用）
dispatch(pDouble, [(tIn.gpuResourceID, 0), (tOut.gpuResourceID, 1)], [])
dispatch(pToBuf,  [(tOut.gpuResourceID, 0)], [(bufA.gpuAddress, 1)])
```

这段在做什么：把张量的 gpuResourceID（GPU 资源句柄，驱动侧的唯一标识）填进参数表的 buffer 槽位，与普通 buffer 的 `setAddress` 绑定可以混用在同一张表里；第二行把结果张量作为输入，普通 buffer 作为输出，供最后一段 kernel 搬运。

## How It Works

三轮递进各自回答一个问题：

1. **运行时编译能不能编？** `makeLibrary(source:)`（运行时把源码字符串交给驱动编译）能编译正确语法的 tensor kernel——旧版实验的失败是语法错误，不是前端缺失。
2. **工具链能不能编？** Xcode 26 工具链的 `metal` CLI（命令行编译器）同样编译通过，并打包成 metallib（编译好的着色器库文件）。
3. **GPU 上怎么跑通？** MTL4 命令栈全链路派发：填充、计算、搬回三段 kernel 串联，CPU 逐元素断言。

正确语法是整个实验的核心，逐行看"为什么这样写"：

```metal
#include <metal_tensor>
using namespace metal;

kernel void double_tensor(tensor<device float, dextents<int, 1>> in  [[buffer(0)]],
                          tensor<device float, dextents<int, 1>> out [[buffer(1)]],
                          uint i [[thread_position_in_grid]]) {
    out[i] = in[i] * 2.0;
}
```

- `#include <metal_tensor>`：tensor 类型与相关工具在专门的头文件里。
- `tensor<device float, dextents<int, 1>>`：device 是地址空间（数据放在设备内存）；dextents 是动态维度描述（各维长度运行时才确定，R 是秩，即维度个数），模板参数必须用它，而不是旧的 `extents<uint, N>`。
- `[[buffer(0)]]`：张量绑进参数表的 buffer 槽——张量与普通 buffer 共用槽位体系，这也是"混绑"能成立的原因。
- `[[thread_position_in_grid]]`：当前线程在整张网格里的编号，一行一个元素，1024 个线程并行完成 1024 个元素的 ×2。

数据进出走"搬运模式"，因为 MTLTensor 没有 CPU 指针（`buffer == nil`）：kernel 填充张量（fill）→ kernel 计算（×2）→ kernel 把张量搬回普通 buffer（tensor_to_buffer）→ CPU 读 buffer 验证。

你在真实输出里看到的 `p[0]=0.0 p[1]=2.0 p[1023]=2046.0`，正是这条搬运链终点逐元素断言的结果。

## Pitfalls & Q&A

**1. 编译报 "invalid type … for input declaration"。**
现象：tensor kernel 编译失败，错误指向参数声明。

原因：用了过时写法——`extents<uint, N>`、`tensor_handle`、`tensor_offset`，绑定用 `[[binding(i)]]`。

解法：模板参数改 `dextents<int, R>`，绑定改 `[[buffer(i)]]`，并 `#include <metal_tensor>`（2026-09 实测）。

**2. 以为 tensor kernel 必须走 ML 专用编译或派发路径。**
现象：在找"机器学习管线状态"之类的专用入口。原因：把"ML Command Encoder 需要特化二进制"误推广到所有张量计算。

解法：`dextents` + `[[buffer]]` 语法下，tensor 参数在普通 kernel 入口就能用、经普通 compute（GPU 计算管线）派发即可。

**3. CPU 直接读张量拿不到数据。**
现象：想在 CPU 侧读取张量内容验证，发现没有可用指针。原因：MTLTensor 无 CPU 指针（lab 27 的 private 分配边界）。

解法：加一段 kernel 把张量写回普通 buffer，再从 buffer 读——本实验的 tensor_to_buffer 就是这个角色。

**Q：Shader ML 与 ML Command Encoder 的边界到底在哪？**
手写 tensor shader 不受任何模型编译链限制：语法对、编译链对就能跑。

而 ML Command Encoder 派发完整网络仍需要 Core ML（Apple 的机器学习模型运行时）GPU 特化二进制，命令行编译链不产出（见 lab 28）。前者是"自定义算子"的自由路，后者是"整网推理"的正规军。
