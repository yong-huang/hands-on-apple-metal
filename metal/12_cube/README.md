# 12 · 3D 立方体：透视投影与深度测试

> 前九个实验都在二维平面里打转——三角形、矩形、渐变，本质是"把数画到屏幕"。
> 进入 3D 需要三件新事物：投影矩阵、深度缓冲、还有"绕着物体转"的相机。
> 本实验把前两样补齐，搭出后续所有 3D 实验（光照/阴影/延迟）的骨架。

## 1. 为什么需要它

立方体 = 12 个三角形，但直接画出来是一团乱色：后面的面会盖住前面的面。要让它"像"立方体，必须回答两个问题：**3D 点落在屏幕哪里**（投影）和**谁挡住谁**（深度）。这两个机制是所有实时 3D 的地基。

## 2. 总览：核心机制一图看懂

![3D 立方体架构](images/cube.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/12_cube/images/cube.html)（或本地打开 [`images/cube.html`](images/cube.html)）。

顶点缓冲与 MVP 矩阵汇入 `vertex_main`，经深度测试后呈现。一句话心智模型：**MVP 决定"在哪"，深度缓冲决定"谁在前"**。

## 3. 快速开始

```bash
./cube.sh               # 一条龙：build → observe → clean
AUTO_QUIT=6 ./cube.sh observe   # 6 秒自动退出
```

控制台输出（真实）：

```
立方体顶点数: 36（6 面 × 6 顶点），深度格式 depth16Unorm
```

窗口中可见六色立方体绕 Y 轴缓慢旋转。验证方法：旋转时近面始终遮挡远面——关闭深度状态（注释 `setDepthStencilState` 一行）重跑，画面立刻"内外翻转"。

## 4. 核心概念

### 4.1 36 个顶点从哪来

6 个面 × 每面 2 个三角形 × 3 顶点。面由 4 个角点 + 面色定义，法线由"边向量叉积"算出（11 会用）。不含索引时顶点有重复——用上 04 的索引缓冲可省 8 个。

### 4.2 MVP 矩阵

`P × V × M`：模型（自转）→ 视图（相机在 z=3.2 看原点）→ 投影（60° 视锥）。乘法顺序从右往左作用。矩阵全部用 simd 手写（`perspective` / `lookAt` / `rotationY`），不依赖第三方库。

### 4.3 深度测试

`MTLView.depthStencilPixelFormat = .depth16Unorm` 后，`currentRenderPassDescriptor` 自带深度附件；`DepthStencilState` 设 `less` + 写深度。**注意管线描述符的 `depthAttachmentPixelFormat` 必须与 view 一致**，否则创建管线直接失败。

### 4.4 易错点

- **Metal 裁剪空间 z ∈ [0,1]**（OpenGL 是 [-1,1]）——25 实验实测过照抄 GL ortho 的后果。
- 忘了给 view 设深度格式 → 深度附件不存在，面片绘制顺序随机。
- 矩阵乘法顺序写反 → 立方体"消失"（被变换出裁剪空间）。

## 5. 关键 API 与字段

```swift
// 每帧：角度→矩阵→Uniform 缓冲（16 个 float）
var uni = Uniforms(mvp: proj * viewM * model)
memcpy(uniformBuffer.contents(), &uni, MemoryLayout<Uniforms>.stride)
encoder.setDepthStencilState(depthState)          // 深度测试开启
encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
```

为什么每帧只更新 Uniform：矩阵 64 字节，替换成本几乎为零；重传 36 顶点则浪费——与 05 的思想一脉相承。

## 6. 文件结构

```
10_cube/
├── README.md                  # 本文档
├── cube.sh                    # 主演示脚本（AUTO_QUIT 自动退出）
├── main.swift                 # 入口包装：调 runCube()
├── cube.swift                 # 实验程序：几何/矩阵/管线/渲染
└── images/
    ├── cube.dataflow.json     # 图源（Typed JSON IR）
    ├── cube.html              # 交互版架构图
    └── cube.svg               # 双主题矢量版（上文内嵌）
```

## 7. 深入要点

- **透视投影矩阵做了什么？** 把视锥体压缩成标准立方体：x/y 除以深度产生近大远小，z 归一到 [0,1] 供深度测试。
- **深度测试的完整链路？** view 声明深度格式 → 管线声明 depthAttachmentPixelFormat → Pass 深度附件 clear=1 → DepthStencilState(less, write)。
- **为什么 z 约定容易踩坑？** Metal NDC z ∈ [0,1] 与 GL [-1,1] 不同；GL 风格投影在 Metal 上会整体裁剪且无报错。
- **36 顶点还是 8 顶点 + 24 索引？** 每面需要独立法线/颜色时顶点不能共享——顶点复用与属性解耦是网格设计的核心权衡。

## 8. 总结

3D 骨架立起来了：投影给位置，深度给遮挡。下一篇给表面加"光照"——法线登场，明暗随光源流转。

→ 下一篇：[11 · 光照立方体](../13_lit_cube/README.md)
