# 02 · SwiftUI Shader 特效：三个自写 shader 由 Slider 驱动

> SwiftUI 14+ 把 Metal 的门槛拆到了门口：写一个 .metal 函数，
> `colorEffect` / `distortionEffect` / `layerEffect` 三个修饰符直接调用——
> 不写管线、不建图层。本实验用三个 Slider 实时驱动它们，并以像素断言自检。

## 1. 为什么需要它

前一个项目拿到了渲染循环的所有权，但代价是要自己管理一切。SwiftUI Shader API 走另一极：**只写像素函数，框架托管全部管线**。理解它的编译/加载链路（.metal → metallib → ShaderLibrary 查找）才能在"方便"与"可控"之间做正确的工程选择。

## 2. 总览：核心机制一图看懂

![SwiftUI Shader 数据流](images/swiftui_shader.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/system/02_swiftui_shader/images/swiftui_shader.html)（或本地打开 [`images/swiftui_shader.html`](images/swiftui_shader.html)）。

Effects.metal 经 metal CLI 编成 default.metallib（SwiftUI ShaderLibrary 的查找对象），三个 shader 由 Slider 实时驱动叠加。一句话心智模型：**colorEffect 改颜色，distortionEffect 改采样位置，layerEffect 回采原图任意处**。

## 3. 快速开始

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

## 4. 核心概念

### 4.1 三种效果的分工

| 修饰符 | 函数签名要点 | 用途 |
|:---|:---|:---|
| `colorEffect` | `(half4 color, …) → half4` | 逐像素调色（本例：双色调） |
| `distortionEffect` | `(float2 position, …) → float2` | 扭曲采样位置（本例：水波） |
| `layerEffect` | `(half4 color, SwiftUI::Layer, float2 pos, …)` | 回采原图任意处（本例：故障错位） |

### 4.2 编译与查找链路（swiftc 工作流的关键）

`.metal` 必须编译成 **default.metallib 且放在可执行文件旁**——裸二进制的 `Bundle.main` 就是可执行文件所在目录，`ShaderLibrary` 在那里查找。metal CLI 需要完整 Xcode（`DEVELOPER_DIR` + `SDKROOT` 指向 Xcode SDK），`SwiftUI::Layer` 类型由 SDK 的 `SwiftUI/SwiftUI_Metal.h` 提供。

### 4.3 双重验证的设计

独立自检进程（无 SwiftUI）做两件事：①运行时编译同一 duotone 公式在 GPU 跑 0/1 两档断言像素变化（数学正确）；②加载 CLI 编译的 default.metallib 断言函数表包含 duotone/ripple/glitch（产物正确）。UI 体验 + 像素断言双保险。

### 4.4 易错点（全部实测踩过）

- 头文件名是 `SwiftUI/SwiftUI_Metal.h`（网上常见的 `SwiftUI_M.h` 不存在于 SDK）。
- `SwiftUI::Layer` 类型让 CLI 编译的库 `makeFunction` 崩溃/挂起——**含 Layer 的库只给 SwiftUI 用，别在自检里派发**。
- `withMemoryRebound(to: [SIMD4<Float>].self)` 把裸内存重释成 Array 是未定义行为（swift_retain 崩溃）——回读用朴素下标循环。
- `layerEffect` 的 `maxSampleOffset` 必须覆盖最大位移，否则采样越界出黑边。

## 5. 关键代码

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

## 6. 文件结构

```
02_swiftui_shader/
├── README.md                      # 本文档
├── swiftui_shader.sh              # 主演示脚本（metal CLI + swiftc + 自检进程）
├── Effects.metal                  # 三个 shader：duotone / ripple / glitch
├── swiftui_shader.swift           # @main SwiftUI App：Slider 驱动 + 程序化测试图
├── shader_check.swift             # 独立自检进程：GPU 数学 + metallib 函数表断言
└── images/
    ├── swiftui_shader.dataflow.json # 图源
    ├── swiftui_shader.html          # 交互版
    └── swiftui_shader.svg           # 双主题矢量版
```

## 7. 深入要点

- **ShaderLibrary 的查找时机？** 渲染首次用到时惰性解析；找不到函数的失败发生在渲染帧而不是编译期——启动即自检是必要的。
- **参数怎么传？** `ShaderLibrary.duotone(.float(x))` 按位置对应函数参数；支持 float/数组/纹理——纹理参数可做"双输入"效果。
- **swiftc 工作流的坑？** 系统默认 SDK 接口不含 DisplayLink/layerClass 等新成员时，切 `SDKROOT` 到 Xcode SDK；单文件 `@main` 加 `-parse-as-library`。
- **什么时候不用 SwiftUI Shader？** 需要多 pass、自定义 drawable 呈现、或非矩形绘制域时——回到项目 1 的手写管线。

## 8. 总结

SwiftUI 的 shader 快车道跑通：框架托管管线，你只写像素数学。两种路线（手写管线 × 托管特效）从此都在工具箱里。下一篇开始把真实世界接进来——相机实时滤镜。

→ 下一篇：[03 · 相机实时滤镜]（清单 docs/metal_system.md 项目 3，待实现）
MDEOF
echo "README 02 done"