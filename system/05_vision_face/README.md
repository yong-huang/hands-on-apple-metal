# 05 · Vision 人脸检测 → Metal 实时马赛克

> 相机画面里的脸要打码——检测在 CPU（Vision），涂抹在 GPU（Metal fragment）。
> 两者通过一块共享纹理和一小组 uniform 协作，30fps 实时无卡顿。
> 这是"CPU 侧 AI + GPU 侧渲染"协作的最小完整案例。

## 1. 为什么需要它

AI 推理结果的"消费端"几乎总是渲染。本实验演示两者的正确握手：Vision 在相机回调队列做检测（不占主线程），检出的人脸矩形以 uniform 传给 fragment，马赛克量化完全在 GPU 完成——检测与渲染解耦，各自全速。

## 2. 总览：核心机制一图看懂

![Vision 人脸马赛克数据流](images/vision_face.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/system/05_vision_face/images/vision_face.html)（或本地打开 [`images/vision_face.html`](images/vision_face.html)）。

相机帧分两路：一路进 Vision 检测出人脸矩形，一路作为纹理直通 fragment；fragment 用人脸矩形对纹理采样位置做块状量化。一句话心智模型：**CPU 出"哪里"，GPU 出"怎么画"**。

## 3. 快速开始

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

## 4. 核心概念

### 4.1 Vision 同步检测的线程模型

`VNImageRequestHandler.perform([request])` 在相机回调队列同步执行——不占主线程，结果在本队列立即可用。检测耗时 ~10ms/帧（M5 Pro，720p），30fps 预算内。

### 4.2 归一化矩形与坐标转换

Vision 的 boundingBox 是归一化坐标、原点在**左下**。本项目显示侧的 uv 原点也在左下（全屏三角形的 uv 定义），坐标直接可用——但显示画面做了水平镜像，所以矩形的 x 要做 `1 − x − w` 翻转（Swift 侧完成，shader 收到的已是镜像后坐标）。

### 4.3 fragment 马赛克

检出矩形内的像素：把 uv 量化到块中心（`floor(local)+0.5`）再采样——每块显示同一颜色，即马赛克。矩形外原样输出。块大小是 uniform 可调参数。

### 4.4 每帧最多 8 张脸

`Uniforms.rects` 固定 8 个 float4 槽位——uniform 缓冲大小编译期确定，超出截断。实际场景单人/双人为主，8 个绰绰有余。

## 5. 关键代码

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

```metal
// fragment：人脸矩形内量化采样
float2 blocked = (floor(local) + 0.5) * blockSize + r.xy;
c = cam.sample(camSmp, blocked);
```

## 6. 文件结构

```
05_vision_face/
├── README.md                       # 本文档
├── vision_face.sh                  # 主演示脚本（最小 .app 打包 + 权限声明）
├── vision_face.swift               # 实验程序：相机 + Vision + 马赛克渲染
└── images/
    ├── vision_face.dataflow.json   # 图源
    ├── vision_face.html            # 交互版
    └── vision_face.svg             # 双主题矢量版
```

## 7. 深入要点

- **Vision 检测为什么放回调队列？** 与渲染共享帧数据但互不阻塞；检测 ~10ms 在 33ms 帧预算内，无需独立队列。
- **马赛克为什么在 fragment 而不是 compute？** 每像素独立、单 pass、直接写入 drawable——fragment 是最小形态；compute 适合需要共享/多 pass 的场景。
- ** rects 定长 8 的取舍？** uniform 缓冲大小固定、GPU 端循环上限编译期已知；人群场景可改间接参数或纹理查找。
- ** Vision 检测帧率与渲染帧率解耦了吗？** 本实验同步跑（每帧都检测）；检测耗时波动时渲染跟着降——解耦方案见 26（异步管线）。

## 8. 总结

CPU 侧 AI + GPU 侧渲染的协作模式跑通，视觉类应用的地基打好。下一篇是三路基准之后的又一个必练项——把 GPU 上的多 pass 管线编排起来。

→ 下一篇：[27 · 融合 GEMM+GELU](../../operator/27_fused_gemm_act/README.md)
MDEOF
echo "README 05 done"