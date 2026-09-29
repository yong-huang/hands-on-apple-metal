# 10 · EDR 扩展动态范围渲染

> 用 Metal 渲染出超出"纯白"的亮度值，在 HDR 屏上呈现一个真正比白色更亮的绿色光斑。读完本篇你能理解 EDR 的三个必要配置（浮点像素格式、扩展色彩空间、屏幕余量），并掌握在 macOS 上渲染超白亮度的完整做法。

## Background

传统显示有一个根深蒂固的约定：屏幕能显示的最亮颜色就是"纯白"，用数值 1.0 表示。所有颜色都被压在 0 到 1 这个范围里。

真实世界不是这样。太阳的反光、金属上的高光、夜里的霓虹灯，亮度都远超一张白纸。想在屏幕上表现它们，常见做法是色调映射（tone mapping，把超亮部分按比例压回 0..1 之内）：画面能看，但高光一律被压平，和白色一样亮，"光感"丢失了。

另一条路是 HDR（High Dynamic Range，高动态范围）视频标准（如 HDR10），它确实能表达更亮的内容，但编码管线面向视频文件，重量级且不适合实时渲染的界面。

Apple 的解法是在系统显示栈里加入 EDR（Extended Dynamic Range，扩展动态范围）：维持"白 = 1.0"的约定不变，同时允许像素值超过 1.0，超出的部分由支持 HDR 的屏幕真正显示出更高的亮度。对渲染程序来说，改动只有几处配置。

## What

EDR 是 Apple 的显示机制：把 SDR（Standard Dynamic Range，传统显示的 0..1 亮度约定）的白色固定为 1.0，同时允许浮点像素携带大于 1.0 的分量，HDR 屏幕按自身能力把这些值显示为比白更亮的实际亮度。

一句话公式（本实验的核心概念）：

`rgba16Float` 精度 + `extendedLinearSRGB` 色彩空间 + EDR headroom = 亮度可超 SDR 白

三个词分别指：

- rgba16Float：每通道 16 位浮点的像素格式，能存 5.0、8.0 这类超过 1.0 的值。
- extendedLinearSRGB：线性 sRGB 色彩空间的扩展版本。sRGB 是普通屏幕的标准色彩空间，"线性"指数值与亮度成正比；"扩展"指取值不限于 0..1。
- headroom（余量）：屏幕能超出 SDR 白的最大倍数，由显示器硬件与系统设置决定。

可以把 SDR 想象成一把只刻到 1.0 的尺子：无论画什么，最亮就到头。EDR 是同一把尺子在 1.0 之后接了一段延长刻度，接多长由屏幕决定。

但和尺子刻度无限延长不同的是：headroom 是物理上限。headroom 为 4 的屏，5.0 的值也只能按 4 显示；headroom 为 1 的普通屏（不支持 HDR），超白值完全看不出差别。

## When to Use

典型场景：

- 查看器类应用显示 HDR 照片或逐帧呈现 HDR 视频，让高光保留原始亮度。
- 实时特效里让光源真的"亮过白"：霓虹灯、太阳、爆炸、魔法光效。
- 相机取景器的 HDR 预览链路。

何时不用：内容本身就是 SDR（普通界面、普通图片）时，用 16 位浮点格式只会白白多花一倍带宽和功耗；目标屏幕不支持 HDR（headroom 为 1）时，EDR 没有任何视觉收益，用色调映射把高光压进 0..1 即可。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| SDR（8 bit 整数格式） | 1.0 封顶，兼容一切屏幕 | 普通 UI 与 SDR 内容 |
| EDR（rgba16Float） | 值可超 1.0，靠屏幕 headroom 呈现 | 实时渲染中的 HDR 高光 |
| HDR10 等 HDR 视频管线 | 面向视频文件的标准化 HDR 编码 | 制作或播放 HDR 视频文件 |
| 色调映射（tone mapping） | 把超亮压回 0..1 显示 | 屏幕不支持 HDR，或要统一外观 |

## Quick Start

前置条件：macOS 加 Swift 编译器 `swiftc`；内置 XDR 屏（Apple 的高亮度屏幕，如 MacBook Pro 内置屏）或支持 HDR 的外接屏才能看到超白亮度，普通屏上程序照常运行但没有可见差异。

这是 GUI 实验：脚本默认让窗口打开 6 秒后自动退出（用环境变量 `AUTO_QUIT` 调整秒数）。

```bash
./edr.sh
```

预期输出（命令行部分，按脚本推断；窗口会先打开约 6 秒再自动退出）：

```
=====> [build] swiftc -parse-as-library -O edr.swift
OK

=====> [observe] EDR HDR 渲染
实验结束。
```

验证方法：看窗口。暗色背景上有一个来回移动的绿色光斑；在 HDR 屏上，光斑中心应当比窗口里任何"白色"元素（如标题栏）更亮。如果光斑最亮处只和白色一样亮，说明当前屏 headroom 为 1（见 Pitfalls 第一条）。

## How It Works

从配置到呈现分四步，对应源码 `edr.swift`。

1. 配置呈现层：CAMetalLayer（Metal 把渲染结果呈现到窗口的专用图层）设置 `pixelFormat = .rgba16Float` 与 `colorspace = extendedLinearSRGB`。前者解决"存得下"超 1.0 的值，后者解决"语义正确"——颜色按线性、可超界的规则解释，两个配置缺一不可。
2. 读屏幕余量：每次刷新从 `NSScreen.main` 读取 `maximumPotentialExtendedDynamicRangeColorComponentValue`（屏幕在当前设置下可超出 SDR 白的最大倍数），作为参数传给着色器。
3. 渲染一帧：全屏三角形加片元着色器（fragment shader，为每个像素算颜色的 GPU 程序），核心代码如下。
4. 呈现：`nextDrawable` 取一块可上屏的纹理（drawable，可提交给屏幕显示的渲染目标），渲染完 `cb.present(drawable)` 提交换帧。

第 3 步的片元着色器：

```metal
fragment float4 fs(VOut in [[stage_in]], constant float &time [[buffer(0)]],
                   constant float &edr [[buffer(1)]]) {
    float2 uv = in.uv;
    float d = length(uv - float2(0.5 + 0.3*sin(time), 0.5));
    float glow = smoothstep(0.4, 0.0, d);
    float3 col = float3(0.1, 0.1, 0.15);
    col += glow * float3(0.0, 5.0, 0.0);
    return float4(col, 1);
}
```

- `d` 是当前像素到光斑中心的距离，中心随 `sin(time)` 左右移动，这就是窗口里光斑会动的来源。
- `smoothstep(0.4, 0.0, d)`：距离为 0 时取 1，达到 0.4 时取 0，中间平滑衰减，形成柔和的光晕边缘。
- `col += glow * float3(0.0, 5.0, 0.0)`：光斑中心绿色分量达到 5.0，是 SDR 白的 5 倍。超过 headroom 的部分由系统压缩或截断，headroom 5 以上的屏才能完整显示。
- `edr` 参数（buffer(1)）由 CPU 传入，但本实验的着色器体尚未使用它——这是"把屏幕能力交给着色器"的预留接线，供按 headroom 缩放亮度时使用。

## Pitfalls & Q&A

坑：SDR 屏上完全看不出效果。现象是光斑中心和白色 UI 一样亮。原因是当前屏 headroom 为 1，超过 1.0 的值无处安放。解法是换内置 XDR 屏或支持 HDR 的外接屏验证。

坑：配置只做了一半。现象是超亮值被截成 1.0，或颜色看起来发灰发暗。原因是像素格式与色彩空间必须成对出现：用 8 bit 整数格式存不下 5.0，用非扩展色彩空间时取值仍按 0..1 解释。

解法是同时设置 `.rgba16Float` 与 `extendedLinearSRGB`（见 How It Works 第 1 步）。

Q：headroom 为什么叫 "Potential"（潜在）？

`maximumPotentialExtendedDynamicRangeColorComponentValue` 表示屏幕在当前设置下"可能达到"的最大倍数；

实际瞬时余量还会随屏幕正在显示的内容变化，NSScreen 上另有反映当前值的 `maximumExtendedDynamicRangeColorComponentValue` 属性。

Q：顶点坐标的 z 传 0 就够了吗？够。Metal 裁剪空间（clip space，顶点坐标的标准参考系，超出 [-1,1] 的部分会被裁掉）的 z 范围是 [0, 1]，与 OpenGL 的 [-1, 1] 不同；本实验的全屏三角形 z 取 0，正好在范围内。从 OpenGL 迁移代码时这里容易踩。
