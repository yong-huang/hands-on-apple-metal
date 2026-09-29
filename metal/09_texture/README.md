# 09 · 纹理贴图：颜色来源的第三代

> 着色器（shader，运行在 GPU 上的小程序）公式能画出规则图案，却画不出一张照片——真实图像的每个像素是"数据"而非"函数"。把图像搬上 GPU 需要两个对象：装数据的 `MTLTexture`（纹理）与定规则的 `MTLSamplerState`（采样器）。读完本篇，你能把一张纹理贴到屏幕中央的矩形上，并理解 GPU"取图上色"的完整链路。

## Background

在着色器里决定一个像素的颜色，此前只有两条路：把颜色存在顶点（构成三角形的角点）上，由 GPU 在三角形面内插值（即顶点色）；或者在片元着色器（为每个候选像素计算颜色的 GPU 程序）里用公式逐像素现算。

这两条路在真实图像面前同时失灵：一张照片、一帧视频有几百万个颜色值，彼此独立、没有数学规律——公式写不出，顶点也存不下。想在 3D 模型表面贴一张木纹图，靠"算"是算不出来的。

新做法应运而生：把图像当作数据整块搬上 GPU，着色器按坐标去"取"颜色，这个动作叫采样（按坐标从图像中取颜色）。

纹理由此成为 3D 模型、视频帧、后处理（对渲染完成的整屏画面再做模糊、调色等处理）乃至计算着色器（不画图、专做通用数据运算的着色器）读写数据的共同载体，`MTLTexture` 也成为与 GPU 打交道频率最高的资源对象之一。

## What

纹理（`MTLTexture`）是 GPU 上带像素格式（声明每个像素的数值如何解释成颜色）与布局的二维图像容器；采样器（`MTLSamplerState`）是一组独立的"怎么取颜色"规则对象。数据本身经 `replace()` 从 CPU 数组上传进纹理。

一句话心智模型：**纹理是数据，采样器是取数规则，uv 是取数地址**（uv：归一化到 [0,1] 的贴图坐标）。

可以把整套机制想象成查字典：纹理是字典正文，uv 是页码加坐标，采样器是查字规则——坐标落在两个字之间怎么办、页码超出范围怎么办。但和纸质字典不同的是，GPU 上每个像素都要查一次，几十万次查询由硬件并行完成。

## When to Use

典型场景——在做什么事的时候会用到：

- 显示真实图像：照片查看器、视频播放器把解码后的帧上传纹理再上屏。
- 给 3D 模型贴材质：模型表面的木纹、砖墙都来自纹理，网格（组成模型的三角形集合）只提供形状。
- 后处理整屏画面：先把场景渲染进一张纹理，再做模糊、调色。

何时不用：

- 图案有数学规律（棋盘、渐变）：逐像素公式直接算，免掉数据上传。
- 颜色只有寥寥几个值：顶点色足够。
- 只传少量参数给着色器：用缓冲（`MTLBuffer`，线性字节数组）而不是纹理。

同类方案对比：

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| 顶点色 | 颜色绑在几何顶点上，数量有限 | 纯色块、简单颜色插值 |
| 逐像素公式 | 零数据上传，但只能表达有规律的图案 | 棋盘、渐变这类程序化图案 |
| `MTLBuffer` 缓冲 | 线性字节数组，不能按 uv 采样、无硬件过滤 | 顶点数据、uniform（CPU 传入、所有像素共享的只读参数）、计算数据 |
| `MTLTexture`（本实验） | 带格式与布局的图像，支持采样与硬件过滤 | 一切真实图像数据 |

## Quick Start

前置：macOS + Xcode（本实验基于 Metal，Apple 的底层 GPU 图形 API）。运行：

```bash
./texture.sh               # 一条龙：build → observe → clean
AUTO_QUIT=6 ./texture.sh observe   # 6 秒自动退出
```

控制台真实输出（节选）。Swift 程序本身不打印任何内容，结果看窗口画面。若窗口未出现，回到终端看 build 段是否报错——未安装 Xcode 命令行工具时 `swiftc` 命令不存在：

```
=====> [build] swiftc -O main.swift texture.swift（几秒钟）
编译完成 → .build/texture
=====> [observe] 运行实验（窗口会打开；……）
实验结束。
=====> [clean] 删除 texture 等编译产物
已清理。
```

观察要点：窗口中央一个矩形，表面是程序内生成的图案纹理（本实验不依赖外部图片，CPU 逐像素构造数据后上传，保证克隆即可跑通）。

验证方法：把采样器的过滤模式从 `linear` 换成 `nearest` 重编译——纹理放大后从平滑插值变成明显马赛克，这就是两种过滤模式的直观差异。

创建资源的核心代码来自 `texture.swift`。这段在做什么：先声明并创建纹理、把 CPU 数组里的像素灌进去，再配置采样器的取数规则——放大缩小都用线性插值，uv 越界锁边：

```swift
// 纹理描述符：尺寸 + 像素格式 + 只读用途
let desc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
desc.usage = [.shaderRead]
let texture = device.makeTexture(descriptor: desc)!
texture.replace(region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)

// 采样器描述符：放大/缩小都用线性，越界锁边
let sdesc = MTLSamplerDescriptor()
sdesc.minFilter = .linear; sdesc.magFilter = .linear
sdesc.sAddressMode = .clampToEdge; sdesc.tAddressMode = .clampToEdge
```

- `rgba8Unorm`：每通道 8 位、0–255 归一化到 0–1 的像素格式；`usage = [.shaderRead]` 声明纹理只被着色器读取。
- `bytesPerRow: w * 4`：每行字节数 = 每像素 4 字节 × 宽度，`replace()` 按行搬运数据。

## How It Works

数据流：CPU 像素数组经 `replace()` 上传成 `MTLTexture`，与 `MTLSamplerState`（linear 过滤）一起在片元着色器中按 uv 采样，输出贴图矩形。三样东西各司其职：数据、规则、地址。

**纹理侧**：描述符（描述"要创建什么"的配置对象）声明像素格式、尺寸与用途；数据经 `replace(region:, bytesPerRow:, bytes:)` 灌入。统一内存（CPU 与 GPU 共享同一块物理内存的架构）时代这一步依然必要——纹理有专门的布局与平铺优化，不是裸字节数组。

**采样器侧**：uv 落在两个纹素（纹理上的单个像素）之间时，`linear` 用双线性插值（取周围 4 个纹素的加权平均）取值；`nearest` 直接取最近纹素，放大后成马赛克。

uv 越界 [0,1] 时由寻址模式决定：`clamp` 锁边、`repeat` 平铺。本实验用最常见、最稳妥的 `linear + clamp` 组合。

**绑定侧**：`draw(in:)` 里多了两行——`setFragmentTexture(tex, index: 0)` 对应着色器注解 `[[texture(0)]]`，`setFragmentSamplerState(sampler, index: 0)` 对应 `[[sampler(0)]]`。

这是绑定槽机制：CPU 把资源挂到编号插槽，着色器按编号取用。槽序号必须与注解严格一致——错位不报错，但数据会送错门。

它与顶点数据的 `[[buffer(0)]]` 是同一套体系，只是换了资源类型。

为什么纹理要 `replace()` 而缓冲用 `makeBuffer(bytes:)`：纹理有独立的内存布局（行对齐、分块平铺），必须按布局搬运；缓冲是线性内存，可以就地构造。

## Pitfalls & Q&A

踩坑清单（现象 + 原因 + 解法）：

- 画面出现斜条纹。原因：`bytesPerRow` 没按 64 字节对齐，`replace()` 读到的每行起点错位。解法：按对齐要求计算每行字节数再传入。
- 颜色异常。原因：纹理像素格式与着色器读回类型不匹配。解法：两者保持对应——`rgba8Unorm` 纹理采样回 `float4`。
- 贴图上下颠倒（最常见的首跑现象）。原因：uv 原点在左上，而 NDC（Normalized Device Coordinates，归一化设备坐标，原点在屏幕中心的坐标系）原点在中心，两个坐标系 y 方向不一致。解法：按坐标系关系翻转 y 方向（如采样时用 `1 - uv.y`）。

深入问答：

- **`linear` 和 `nearest` 怎么选？** linear 双线性插值、放大平滑，一般显示的默认选择；nearest 保留像素感且省计算，像素风与调试常用。纹理缩小到远小于原始尺寸时，要 mipmap（预先生成的逐级缩小纹理副本）配合，否则会闪烁。
- **uv 越界还有别的处理方式吗？** 寻址模式还提供 `repeat` 平铺与 `mirror` 镜像。想让一张小图铺满地面，`repeat` 一行代码就够。
