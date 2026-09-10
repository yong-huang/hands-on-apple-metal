# Apple Metal 学习博客目录

配合 `0x_learn_metal/LearnMetal/LearnMetal/Programs/` 下 9 个小项目的渲染程序，本目录按项目逐篇记录领域知识、代码架构与延伸思考，对应 `0x_learn_metal/metal.md` 路线图的前两个阶段。

## 阶段一：Metal 基础入门（1-5）

| # | 项目 | 博客 | 领域重点 |
|:--|:--|:--|:--|
| 01 | GPU 设备 | [01_GPUInfo.md](./01_GPUInfo.md) | `MTLDevice`、能力探测、统一内存 |
| 02 | 命令队列 | [02_CommandQueue.md](./02_CommandQueue.md) | `MTLCommandQueue` / `MTLCommandBuffer` 三层骨架 |
| 03 | 第一个三角形 | [03_Triangle.md](./03_Triangle.md) | `MTKView`、渲染管线、NDC、顶点/片元着色器 |
| 04 | 彩色矩形 | [04_Rectangle.md](./04_Rectangle.md) | 索引缓冲 + TriangleStrip |
| 05 | 动画旋转三角形 | [05_AnimatedTriangle.md](./05_AnimatedTriangle.md) | Uniform Buffer、旋转矩阵、逐帧变换 |

## 阶段二：着色器特效（6-9）

| # | 项目 | 博客 | 领域重点 |
|:--|:--|:--|:--|
| 06 | 棋盘格 | [06_Chessboard.md](./06_Chessboard.md) | 全屏四边形、`fract`/`step` 空间重复 |
| 07 | 圆形 | [07_Circle.md](./07_Circle.md) | 距离场、`length`、`smoothstep` 抗锯齿 |
| 08 | 颜色渐变 | [08_Gradient.md](./08_Gradient.md) | `mix` + `smoothstep` 颜色插值 |
| 09 | 纹理贴图 | [09_Texture.md](./09_Texture.md) | `MTLTexture`、`MTLSamplerState`、采样管线 |

## 学习主线（贯穿 9 篇）

1. **数据通路**：`position/texCoord` → vertex → fragment，`[[buffer(n)]]`/`[[texture(n)]]`/`[[sampler(n)]]` 是 CPU 与 GPU 的"连接暗号"
2. **颜色来源演进**：顶点色(03-05) → 逐像素数学公式(06-08) → 纹理采样(09)
3. **不变脚手架**：6-9 共用"全屏四边形 + 直通顶点着色器"，只换 fragment 就换了整套视觉效果
4. **两个插值工具**：`step`（硬边界，棋盘）vs `smoothstep`（软边界，抗锯齿/渐变），配上 `mix` 完成上色

运行方式：Xcode 打开 `LearnMetal.xcodeproj`，在 `main.swift` 解注释对应 `runXxx()` 入口再运行。