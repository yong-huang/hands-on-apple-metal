# 02 · SwiftUI Shader 特效：三个自写 shader 由 Slider 驱动

> SwiftUI 的 Shader API 让你只写一个 `.metal` 函数，就用 `colorEffect` / `distortionEffect` / `layerEffect` 三个修饰符接到视图上——不写管线、不建图层。本实验用三个 Slider 实时驱动三个自写 shader，并以像素断言自检。读完你将掌握 .metal → metallib → ShaderLibrary 的完整链路与三种效果的分工。

## Background

在 SwiftUI 里做 GPU 特效，此前的选择只有两类。

一是内置修饰符（`blur`、`shadow` 等），数量有限，表达不了自定义数学；二是手写完整渲染管线——MTKView 或 CAMetalLayer 加自己的渲染循环（见 01_cametal_layer），自己管理 drawable（GPU 的屏幕呈现缓冲）、管线状态与顶点数据。

痛点出在需求与工具的错位。很多需求只是"给一段 UI 加个逐像素的颜色变换"，比如把图片处理成双色调、给文字加水波。为这个建一整套渲染循环，工程量与需求不成比例；只用内置修饰符，又写不出自己想要的公式。

SwiftUI 14+ 提供的 Shader API 就是为这个缝隙设计的：把 `.metal` 函数编译成 metallib，框架在渲染该视图时替你派发，你只提供像素函数和参数。管线、图层、缓冲全部不用管。

## What

SwiftUI Shader API 是一组视图修饰符（`colorEffect` / `distortionEffect` / `layerEffect`），把你写好的 shader（在 GPU 上对每个像素执行的小函数）接到任意 SwiftUI 视图的渲染过程上。你写像素级数学，框架托管其余一切。

一句话心智模型：**colorEffect 改颜色，distortionEffect 改采样位置，layerEffect 回采原图任意处**。可以把三个修饰符想象成三支笔：第一支只能改笔尖的颜色，第二支决定笔尖落在哪里，第三支能把画好的部分再蘸起来重画。

但和笔不同的是：三支笔不是三选一，可在同一个视图上叠加使用；且第三支"蘸起来重画"的是原视图的渲染快照，只能采样、不能反向修改布局。

三种效果的分工：

| 修饰符 | 函数签名要点 | 用途 |
|:---|:---|:---|
| `colorEffect` | `(half4 color, …) → half4` | 逐像素调色（本例：双色调） |
| `distortionEffect` | `(float2 position, …) → float2` | 扭曲采样位置（本例：水波） |
| `layerEffect` | `(half4 color, SwiftUI::Layer, float2 pos, …)` | 回采原图任意处（本例：故障错位） |

## When to Use

在给 SwiftUI 界面加实时视觉特效时用它：图片滤镜、双色调、故障艺术、水波扭曲，都是"一个函数 + 几个参数"就能表达的效果。

在需要用控件驱动像素级效果时用它：Slider、动画值可以直接作为 shader 参数传入，每帧重算。

在不想引入渲染循环时用它：需求只是视图外观变换，没有 3D 场景、没有多 pass（一帧内对同一画面连续做多遍渲染，如先画场景再叠模糊），框架托管正合适。

何时不用：需要多 pass、自定义 drawable 呈现、或非矩形绘制域时，回到手写管线（见 01_cametal_layer）；标准图像处理需求可先用 Core Image 的现成滤镜。

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| SwiftUI Shader（本实验） | 框架托管管线，只写像素函数 | UI 特效、单 pass 的视图效果 |
| 手写管线（MTKView / CAMetalLayer） | 渲染循环完全自控 | 多 pass、自定义呈现、引擎化渲染 |
| Core Image | 现成滤镜库为主，也可写自定义 kernel | 标准图像处理，不想写 shader |

## Quick Start

前置条件：完整 Xcode（metal CLI 编译需要 Xcode 的 SDK，环境变量由脚本设置）。运行：

```bash
./swiftui_shader.sh           # 一条龙：build → observe（8 秒 UI）→ verify（独立 GPU 自检）→ clean
```

真实输出：

```
Effects.metal → default.metallib
编译完成 → .build/swiftui_shader + shader_check
自检①：GPU duotone 数学——92.0% 像素被改变
✅ 自检①通过：shader 数学真实生效
自检②：CLI 编译的 metallib 在 GPU 上派发执行——79.8% 像素被 duotone 改变
✅ 自检②通过：CLI 编译产物真实可用
```

窗口中拖三个 Slider：双色调、水波幅度、故障错位实时生效。验证方法：独立自检进程①证明 duotone 数学在 GPU 上改变 92% 像素；②证明 CLI 编译的 metallib 可真实派发。

核心实现代码（三个 shader 中的两个，随后说明这段在做什么）：

```metal
// ② distortionEffect：水波——position 由 SwiftUI 传入
float2 ripple(float2 position, float amount, float time) {
    position.x += sin(position.y * 0.05 + time * 3.0) * amount;
    return position;
}
// ③ layerEffect：回采原图（SwiftUI::Layer 是官方提供的回采句柄）
half4 glitch(half4 color, SwiftUI::Layer layer, float2 position,
             float amount, float time) {
    float band = floor((position.y + time * 120.0) / 48.0);
    float shift = amount * step(0.5, fract(band * 0.5 + floor(time) * 0.5));
    return layer.sample(position + float2(shift, 0));
}
```

- `ripple` 在做水波扭曲：不碰颜色，只把每个像素的采样位置 x 坐标按 sin 波左右摆动，画面就起了涟漪。
- `glitch` 在做故障错位：按 48 像素一行分带，部分带整体水平错位，错位的内容用 `layer.sample` 从原图取回。

## How It Works

这节讲从 `.metal` 源文件到屏幕像素的完整链路。你在 Quick Start 看到的两行 ✅ 自检，就来自对这条链路的两段断言。

数据流是：`Effects.metal` 经 metal CLI 编译成 `default.metallib`，放在可执行文件旁边；SwiftUI 的 `ShaderLibrary` 在 `Bundle.main` 指向的目录里查找它

——裸二进制的 `Bundle.main` 就是可执行文件所在目录，这就是 metallib 必须放在可执行文件旁的原因。

渲染视图时框架派发函数，Slider 的值经 `ShaderLibrary.duotone(.float(x))` 这样的调用按位置传入函数参数。

两个编译环节的约束值得记住：metal CLI 需要完整 Xcode（`DEVELOPER_DIR` + `SDKROOT` 指向 Xcode SDK）；

`SwiftUI::Layer` 类型由 SDK 的 `SwiftUI/SwiftUI_Metal.h` 提供，没有这个头文件，`layerEffect` 的函数签名写不出来。

`ShaderLibrary` 的查找是惰性的：渲染首次用到某个函数时才解析。找不到函数的失败发生在渲染帧而不是编译期——程序能启动、崩在第一帧。这正是实验设计"启动即自检"的原因。

双重验证的设计对应输出的两行：自检①是一个无 SwiftUI 的独立进程，运行时编译同一 duotone 公式，在 GPU 上跑 0/1 两档断言（同一输入分别在效果强度 0 与 1 下各算一遍，断言输出确实改变），数出被改变的像素比例——证明数学正确。

自检②加载 CLI 编译的 default.metallib，取出其中的 duotone_selfcheck 自检内核真实派发一遍（与 SwiftUI 消费的是同一个 metallib 文件）——证明编译产物可用。UI 体验加像素断言，双保险。

## Pitfalls & Q&A

**头文件名写错，`SwiftUI::Layer` 编译不过。** 现象：按网上常见写法 `#include <SwiftUI/SwiftUI_M.h>` 找不到类型。原因：SDK 里不存在这个文件名。解法：用 `SwiftUI/SwiftUI_Metal.h`。

**含 `SwiftUI::Layer` 的库在自检进程里崩溃或挂起。** 现象：对 CLI 编译的 metallib 调 `makeFunction` 时进程异常。

原因：`Layer` 类型依赖 SwiftUI 的运行环境，裸进程不满足。解法：含 Layer 的库只给 SwiftUI 用；自检里只派发不含 Layer 的函数。

**回读 GPU 结果时 `swift_retain` 崩溃。** 现象：`withMemoryRebound(to: [SIMD4<Float>].self)` 把裸内存重释成 Array 后崩溃。原因：这是未定义行为，裸内存没有 Array 的引用计数语义。解法：回读用朴素下标循环逐像素拷贝。

**`layerEffect` 边缘出黑边。** 现象：错位/采样的像素在边缘变黑。原因：`maxSampleOffset` 没有覆盖最大位移，采样越界。解法：把 `maxSampleOffset` 设为不小于 shader 中的最大采样偏移量。

**Q：shader 参数怎么传？** `ShaderLibrary.duotone(.float(x))` 按位置对应函数参数；支持 float、数组、纹理——纹理参数可做"双输入"效果。

**Q：swiftc 工作流还有哪些坑？** 系统默认 SDK 接口不含 DisplayLink/layerClass 等新成员时，切 `SDKROOT` 到 Xcode SDK；单文件 `@main` 加 `-parse-as-library`。
