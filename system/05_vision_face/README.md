# 05 · Vision 人脸检测 → Metal 实时马赛克

> 相机画面里的脸要打码——检测在 CPU（Vision），涂抹在 GPU（Metal fragment）。两者通过一块共享纹理和一小组 uniform 协作，30fps 实时无卡顿。这是"CPU 侧 AI + GPU 侧渲染"协作的最小完整案例。读完你将掌握检测与渲染的握手方式：线程安排、坐标转换与马赛克的 GPU 实现。

## Background

想对相机画面里的人脸打码，朴素做法是把每帧像素读回 CPU，用 CPU 图像库逐块涂抹，再写回显示路径。

这条路在实时场景走不通。逐像素处理在 CPU 上每帧动辄几十毫秒，而 30fps 的帧预算只有 33ms；一路拷贝、一路计算，检测和像素处理还挤在同一个线程里互相拖慢，帧率立刻掉下去。

AI 推理结果的"消费端"几乎总是渲染，正确的分工因此浮出水面：Vision（Apple 的机器视觉框架）在 CPU 侧回答"哪里有脸"，GPU 侧的 fragment shader 回答"怎么画"。检测与渲染解耦，各自全速——本实验把这条协作链路完整跑通。

## What

本实验是一条"CPU 出位置、GPU 出画法"的实时管线：Vision 在相机回调队列检出人脸矩形，矩形以 uniform（一小块 CPU 每帧传给 GPU 的常量数据）传给 fragment shader（片段着色器：GPU 上对每个像素执行的程序），马赛克量化完全在 GPU 完成，30fps 实时。

一句话心智模型：**CPU 出"哪里"，GPU 出"怎么画"**。可以把两者想成导演和画师：导演只递一张写着区域坐标的纸条，画师照着纸条在画布上涂格子。

类比到坐标就要小心：纸条上的坐标必须用双方约定的写法（归一化、原点位置、是否镜像），坐标没对齐，涂出来的就是错位格子。本实验的坐标系处理见 How It Works。

## When to Use

在做实时人脸打码、贴纸、美颜这类应用时用它：检测结果（矩形/关键点）驱动渲染效果，帧率要求高。

在做任何"AI 结果驱动画面"的效果时用它：人体姿态、手势识别、物体检测框，接法与人脸马赛克完全同构。

在隐私要求高的视频处理场景用它：检出即打码，且全程 GPU 完成，不落盘明文画面。

何时不用：离线视频或照片处理，没有实时帧预算，Vision + Core Image 离线批处理更简单；检测结果变化缓慢的场景，也不必每帧都跑检测。

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| fragment 马赛克（本实验） | 效果逐像素在 GPU、单 pass 完成 | 实时视频效果，每像素独立 |
| compute shader（另一类 GPU 程序：不逐像素画图，可自由并行并共享数据） | 可共享数据、多 pass（一帧内连续多遍渲染）编排 | 更复杂的图像处理（模糊、直方图） |
| Core Image（CIDetector + 滤镜链） | 现成检测与滤镜，不写 shader | 标准需求，自定义数学要求不高 |

## Quick Start

前置条件：macOS 与 Xcode 环境；脚本会打包最小 .app 并声明相机权限。运行：

```bash
./vision_face.sh           # 一条龙：build → observe（15 秒）→ clean
# 首次运行需允许相机权限；对准你的脸，检出即打马赛克
```

真实输出：

```
相机已启动，检测到的人脸将实时打马赛克
处理帧率: 30 fps（检出人脸：0）
处理帧率: 31 fps（检出人脸：0）
处理帧率: 31 fps（检出人脸：1）    ← 对准脸后每秒打印检出数
```

验证方法：处理帧率稳定 30-31 fps；对准脸后检出数 ≥1，移出画面归 0——检测跟随实时变化。

Swift 侧的核心代码（随后说明这段在做什么）：

```swift
// 相机回调队列：Vision 同步检测
let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
try? handler.perform([faceRequest])
let faces = (faceRequest.results ?? []).prefix(8)

// 主线程：矩形传 uniform，fragment 马赛克
withUnsafeMutableBytes(of: &u.rects) { ptr in
    for (i, r) in rects.prefix(8).enumerated() {
        ptr.storeBytes(of: r, toByteOffset: i * 16, as: SIMD4<Float>.self)
    }
}
```

- 第一段在相机回调队列里同步跑一次人脸检测，结果最多取 8 张脸。
- 第二段把矩形逐个写进 uniform 缓冲（每个 float4 占 16 字节），渲染时 GPU 就能读到。

fragment 侧的马赛克核心两行：

```metal
// fragment：人脸矩形内量化采样
float2 blocked = (floor(local) + 0.5) * blockSize + r.xy;
c = cam.sample(camSmp, blocked);
```

- 这两行在做块状量化：把矩形内的像素坐标折算到所在块的中心点，再回采相机纹理——每个块显示同一个颜色，马赛克就成立了。

## How It Works

这节按数据流把"检测 → 传坐标 → 涂格子"三步拆开。你在 Quick Start 输出里看到的"检出人脸：1"，就来自第一步；画面上跳动的马赛克，来自后两步。

线程模型是整条管线不卡顿的前提。`VNImageRequestHandler.perform([request])` 在相机回调队列同步执行——不占主线程，结果在本队列立即可用。检测耗时约 10ms/帧（M5 Pro，720p），落在 33ms 帧预算内，无需独立队列。

坐标转换是最容易错的一步。Vision 的 boundingBox 是归一化坐标（0 到 1 的比例值）、原点在**左下**；本实验显示侧的 uv（纹理坐标，横纵均以 0 到 1 表示）原点在左上——它来自全屏三角形的 uv 定义——竖直方向恰好与 Vision 相反。

所以 Swift 侧先把矩形的 y 做 `1 − y − h` 翻转再写 uniform，x 方向两者都从左往右、无需处理。

fragment 马赛克的机制：检出矩形内的像素，把 uv 量化到块中心（`floor(local)+0.5`）再采样——每块显示同一颜色；矩形外的像素原样输出。块大小目前写死在 shader 里（float2(0.016, 0.028)），改这两个数字重新编译即可调马赛克粗细。

每帧最多 8 张脸是刻意的设计：`Uniforms.rects` 固定 8 个 float4 槽位，uniform 缓冲大小编译期确定，超出截断。实际场景单人/双人为主，8 个绰绰有余。

## Pitfalls & Q&A

**马赛克区域和脸对不上。** 现象：打码格子出现在上下颠倒的位置。原因：Vision 的 y 轴向上、shader 的 uv y 轴向下，矩形 y 没有同步翻转。解法：Swift 侧先做 `1 − y − h` 再写 uniform（机制见 How It Works 的坐标转换）。

**Q：马赛克为什么在 fragment 而不是 compute？** 每像素独立、单 pass、直接写入 drawable——fragment 是最小形态；compute 适合需要共享数据/多 pass 的场景。

**Q：`rects` 定长 8 的取舍是什么？** uniform 缓冲大小固定、GPU 端循环上限编译期已知；人群场景可改间接参数或纹理查找。

**Q：检测帧率与渲染帧率解耦了吗？** 本实验同步跑（每帧都检测）；检测耗时波动时渲染跟着降——解耦方案见 26（异步管线）。
