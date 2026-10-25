# 01 · 极光渐变板 Plasma：全屏四边形上的正弦调色

> 给 GPU 一块全屏四边形当画布，让片元着色器逐像素用公式算颜色：
> 四组正弦波叠加出随时间流动的色场，余弦调色板把它染成极光、晚霞或深海。
> 读完本篇你能掌握"整幅画面逐像素算"的完整套路——一段 200 行以内的 Swift 就能让两百万像素听你指挥。

## Background

在 Plasma 之前，屏幕上的流动图案有两种做法：一是让设计师在图像软件里画好序列帧再播放，二是直接循环一段预渲染视频。想要换个配色，就得回炉重新出一版素材。

逐像素用 CPU 算也有过得去的时候，但 1920×1080 约 200 万个像素、每秒 60 次刷新，意味着每秒上亿次浮点求值，CPU 单核立刻力不从心。GPU 的数千个核心天生就是为"每个像素独立算一遍"这种活准备的。

Plasma（等离子色场）源自 1990 年代 demoscene（把机器性能压榨出视听效果的编程社区）的经典效果：用几组正弦波叠加出连续变化的标量场（每个位置各对应一个数值的连续分布），再把这个数值映射成颜色。它公式极简、纯 GPU 计算，成了学习"时间驱动画面"的第一课。

## What

Plasma 是一种程序化生成的流动色场：每个像素的颜色由"空间位置 + 当前时间"经正弦函数算出，整体呈现平滑演变的彩色光带。

![Plasma 数据流](images/plasma.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/creative/01_plasma/images/plasma.html)（或本地打开 [`images/plasma.html`](images/plasma.html)）。

可以把余弦调色板想象成一台自动调音台：输入一个 0 到 1 的滑块值，三个颜色通道各按自己的相位做余弦波动，输出永远平滑过渡的 RGB。但和图片调色不同的是，它的"色表"由 a、b、c、d 四组系数实时决定——换配色只需换系数，不需要重建任何 GPU 资源。

## When to Use

- **动态背景**：应用启动页、舞台大屏、直播叠加层的底色，一段着色器（shader，运行在 GPU 上、对每个像素执行的一小段程序）替代数 MB 的循环视频
- **壁纸与艺术导出**：换随机时间参数批量出图，本项目就带了 1920×1080 离屏导出
- **数据可视化的底场**：给热力图、频谱图垫一层"有生命感"的底色

何时不用：需要表达具体语义（地图、图表、有轮廓的对象）时，色场只是底噪，主体还得靠几何绘制。

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| 循环视频背景 | 素材固定、换色要重渲；播放有解码开销 | 美术资源充足、效果要求电影感 |
| 静态渐变图 | 零开销，但完全不动 | 界面只求柔和底色 |
| Core Image 滤镜链 | CPU/GPU 混合，链路长；擅长对已有图像加工 | 输入是照片视频而非纯生成 |
| **Metal shader 色场** | 一段着色器全 GPU 计算，参数实时可调 | 需要无限变化、实时响应参数的背景 |

## Quick Start

前置条件：装好 Xcode Command Line Tools（终端运行 `xcode-select --install`）；Apple Silicon Mac 自带 Metal（Apple 的 GPU 编程框架，Swift 可直接调用），无需其他依赖。

```bash
./plasma.sh               # 一条龙：build → observe → clean
./plasma.sh observe       # 只观察（产物缺失时自动先 build）；按 C 键切换配色
AUTO_QUIT=6 ./plasma.sh   # 6 秒后窗口自动退出（脚本化验证）
./plasma.sh export out.png 2   # 不开窗口，离屏导出 1920×1080 PNG（配色 2 = 晚霞）
```

真实输出（全新目录执行 `AUTO_QUIT=6 ./plasma.sh observe`）：

```
=====> [build] swiftc -O main.swift plasma.swift（几秒钟）
编译完成 → .build/plasma

=====> [observe] 运行实验（窗口会打开；关闭窗口结束实验。脚本化运行可加前缀 AUTO_QUIT=6（秒）自动退出）
Device: Apple M5 Pro
配色方案：1/3 极光（窗口内按 C 键循环切换）
[Pipeline ready] vertex_main + fragment_main（bgra8Unorm）

实验结束。
```

真实输出（`./plasma.sh export out.png 1`；仓库自带的导出示例 [images/plasma.png](images/plasma.png) 就是这条命令的产物）：

```
=====> [build] swiftc -O main.swift plasma.swift（几秒钟）
编译完成 → .build/plasma

=====> [export] 离屏渲染 1920×1080 一帧 → out.png（配色 1，无窗口）
导出 1920×1080 → out.png（配色：极光，时间 6.28s）
✅ PNG 已写出（1075378 字节）
```

- 观察要点：窗口里是蓝、青、绿、橙多色平滑流动的光带，色带边界永远柔和
- 验证方法：盯着任意一处看 3 秒，颜色应连续演变无跳变；按 C 键整体换色调但流动节奏不变
- 诚实预期：配色名（极光/晚霞/深海）是审美命名，实际观感偏抽象色场；离屏导出用固定时间 6.28 s，重复执行得到逐字节相同的 PNG

## How It Works

**画布：全屏四边形。** 程序只提交 6 个顶点（两个三角形）铺满整个视口。顶点着色器把 NDC 坐标（Normalized Device Coordinates，中心为原点、范围 [-1,1] 的归一化坐标系）直接透传，并顺手换算出每个位置的 texCoord（各像素在画面上的 0~1 坐标）。

真正的图案全部由片元着色器逐像素计算。

**流动：时间 uniform。** uniform 指"每帧由 CPU 一次性传给着色器、着色器只读的数据"。每帧 CPU 把"当前时间减去起点"连同调色板系数写进一个 96 字节的结构体，经 `setFragmentBytes` 下发。

正弦项带着 t 演变，画面就动了——GPU 每帧重算全部像素，没有一帧是缓存的旧图。

**图案：四组正弦叠加。** 代码里的 `p` 是片元坐标（由 texCoord 换算到以画面中心为原点、范围 [-1,1]），`t` 就是上面每帧下发的 uniform 时间：

```metal
float v = 0.0;
v += sin(p.x * 3.0 + t);              // 横向波
v += sin(p.y * 3.5 + t * 1.3);        // 纵向波，速度错开
v += sin((p.x + p.y) * 2.5 + t * 0.7); // 对角波
v += sin(length(p) * 4.0 - t * 1.1);   // 径向波，从中心向外扩散
v = v * 0.125 + 0.5;                   // 4 项各 [-1,1]，归一到 [0,1]
```

四个波各自平滑，相加后依然平滑——这就是色场永无硬边的数学保证。你在窗口看到的每一圈光带，都对应某个正弦项的等值线。

**上色：余弦调色板。** `pal(v) = a + b·cos(2π(c·v + d))`，RGB 三通道共用一个 v、各用一组相位 d。正弦场 v 送进调色板，就得到连续演变的颜色。

三套配色只是三组不同的 a/b/c/d 系数，按 C 键时 CPU 换系数重发 uniforms，管线状态（渲染管线：从顶点到像素的整套 GPU 处理流程，构建一次开销不小）完全不动——切换配色因此零卡顿。

**导出：离屏渲染。** export 模式绕过窗口：建一块 rgba8Unorm 纹理（texture，显存里的一块二维像素数组；rgba8Unorm 即每通道 8 位的普通 RGBA 格式）当渲染目标（本次绘制要画进去的那块内存）。

渲一帧后 `getBytes` 读回像素，经 CoreGraphics 编码成 PNG。时间固定为 6.28 s，输出因此可复现。

## Pitfalls & Q&A

- **窗口不出现，程序却一直运行**：现象是终端打印 Pipeline ready 后迟迟不见界面。原因：swiftc 直出的二进制没有 Info.plist，macOS 默认不给它 regular 应用策略，窗口不显示。
  解法：`app.run()` 前 `NSApp.setActivationPolicy(.regular)`，`makeKeyAndOrderFront` 后 `NSApp.activate(ignoringOtherApps: true)`。
- **`$file（` 让 bash 报 unbound variable**：现象是脚本在 `set -u` 下于变量引用处报 `file: unbound variable`，但变量明明赋了值。原因：macOS 自带 bash 3.2 解析多字节字符有缺陷，`$file` 紧跟全角`（`时会把 UTF-8 首字节并进变量名。解法：变量名后紧跟非 ASCII 字符必须写 `${file}` 定界。
- **Swift 与着色器的结构体布局不一致**：现象是 uniforms 传过去后着色器读到乱值。原因：MSL（Metal Shading Language，Metal 着色器用的语言）的 `float3` 按 16 字节对齐，与 Swift 元组的紧凑排列不同。
  解法：两侧统一用 `SIMD4<Float>` / `float4` 补齐，字段顺序一致，下发长度取 `MemoryLayout<PlasmaUniforms>.stride`。
- **着色器里报 unknown type name**：现象是运行时编译着色器直接失败，报 `PlasmaUniforms` 不存在。原因：Swift 侧定义的类型不会自动出现在 MSL 世界里，着色器源码是独立编译的。
  解法：在着色器源码字符串里用 MSL 语法同名定义一遍该结构体，字段布局与 Swift 侧逐一对齐。
- **窗口不响应按键**：MTKView 默认不接收键盘焦点。解法：子类化并重写 `acceptsFirstResponder` 返回 true，窗口显示后调用 `makeFirstResponder`。

**Q：为什么 6 个顶点而不是 4 个？**
一个矩形需要 2 个三角形；GPU 不认"四边形"这种图元，非索引条件下就是 6 个顶点（metal/04 的索引缓冲可以省回这 2 个）。

**Q：想改出自己的图案从哪下手？**
只改 v 的组成：加减 `sin` 项、换频率系数即可。速度感来自 t 的系数（越大越快），空间尺度来自坐标系数（越大纹理越密）。

**Q：每次 export 的文件为什么逐字节相同？**
导出用固定时间 6.28 s，正弦函数确定性地映射输入到输出，不涉及随机数与计时器。想要"每次不一样"，把时间参数换成随机值即可。
