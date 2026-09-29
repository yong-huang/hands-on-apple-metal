# 09 · Metal 离屏渲染帧序列

> 用 Metal 把 90 帧动画画进一块看不见的内存（离屏渲染），再逐帧回读像素做校验。读完本篇你能掌握"GPU 画完之后把像素拿回来"的标准做法，这是视频导出、后处理和 AI 推理输入的共同前置环节。

## Background

通常意义上的 GPU 绘图，目的地是屏幕：画完，窗口系统把结果显示出来，像素本身并不交还给开发者。

想拿到"画出来的像素"时，老办法有两条路，都不理想。一是截屏：把窗口内容抓成图片，但截屏走窗口合成流程，拿到的是合成后的结果，速度慢，也不适合无人值守的命令行程序。

二是放弃 GPU，用 CPU 直接往像素数组里画：等于丢掉 GPU 的光栅化（rasterization，把几何图形拆成一个个像素的硬件过程）加速能力，实时场景跑不动。

视频导出恰恰需要第二条数据通路：GPU 画好一帧，像素交给编码器压进视频文件；后处理、AI 推理输入也是同样需求。GPU 渲染接口为此提供了"把渲染结果写进一块内存区域、而不是屏幕"的能力，这就是离屏渲染（offscreen rendering）。本实验跑通的就是这条"画进纹理 → 读回像素 → 校验"的最小链路。

## What

离屏渲染是指把 GPU 渲染管线的输出目标从屏幕换成一帧纹理（texture，GPU 内存里的一张二维像素数组），渲染过程对用户完全不可见，产物是一块可进一步处理的像素数据。

可以把屏幕想象成画家只能直接作画于其上的展厅墙面：画完就挂上去了，取不走。离屏渲染相当于递给画家一张可搬运的画布——画完不挂墙，而是送去质检（像素校验）、复印（编码成视频文件）或再加工（滤镜后处理）。

但和搬画布不同的是：纹理里的像素不会自动变成视频文件，也不会自动出现在任何窗口。它只是"数据到位了"，后续编码或显示都需要额外的环节。本实验名里的 mp4_export 指的就是这条链路的最终用途——帧序列是 mp4 导出的原料。

## When to Use

典型场景：

- 把 GPU 渲染的每一帧导出成视频：先离屏画出像素，再交给编码器压缩。
- 后处理链：第一遍渲染进纹理，第二遍把这张纹理当输入做滤镜，再上屏。
- 给 AI 模型供图：渲染结果直接作为模型输入纹理，不经过屏幕。

何时不用：只是把画面显示给用户看，直接渲染进 CAMetalLayer（Metal 提供的、负责把内容呈现在窗口里的图层）即可，离屏加回读是白做的开销。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| 直接渲染到窗口 | 无回读开销，但拿不到像素数据 | 只是显示画面 |
| 离屏渲染 + 回读 | 拿到 CPU 可读像素；回读有同步开销 | 需要像素做校验、分析或喂给模型 |
| AVAssetExportSession | AVFoundation 的高层导出 API，只能转码已有视频文件 | 已有 mp4，只要转格式或裁剪 |
| AVAssetWriter + VideoToolbox | 逐帧把像素编码进视频文件的标准组合（VideoToolbox 是系统视频编解码框架） | 离屏帧序列要落地成 mp4 |

## Quick Start

前置条件：macOS 加 Swift 编译器 `swiftc`（Swift 自带的命令行编译器）。脚本一条命令完成编译加运行，也支持 `build` / `observe` / `clean` 子命令。

```bash
./mp4_export.sh
```

预期输出（按源码推断，非实测；`Device` 行与 fps 因机器而异）：

```
=== Metal 离屏渲染 + 帧序列导出 ===
Device: <GPU 名称>
离屏渲染完成: 90 帧 / <耗时> 秒 = <fps> fps
✅ 离屏渲染验证通过：所有帧均有效
提示: 生产环境的 mp4 导出用 AVAssetWriter + VTCompressionSession（见 08 项目）
```

验证方法：看终端输出。出现 `✅` 即全部抽检帧的非黑像素占比达标；若有帧不达标，会打印 `⚠️ 帧 N: 有效像素比 xx%` 并在结尾显示 `❌ 部分帧无效`。

建离屏纹理的三行配置（这段在做什么：声明一块"既能当画布、又能当读数"的显存）：

```swift
let td = MTLTextureDescriptor.texture2DDescriptor(...)
td.usage = [.renderTarget, .shaderRead]
td.storageMode = .shared
```

- `.renderTarget`：允许 GPU 把它当作渲染目的地画上去。
- `.shaderRead`：允许后续内核或着色器把它当输入读。
- `.shared`：CPU 与 GPU 共享同一块内存，`getBytes` 才能直接回读。

## How It Works

每帧的处理链路分四步，对应源码 `mp4_export.swift`。

1. 启动时编译渲染管线：两个着色器（shader，跑在 GPU 上的小程序）——顶点着色器 vertex shader 负责算出图形的角点位置，片元着色器 fragment shader 负责为每个像素算颜色；两者打包成 render pipeline state（渲染管线状态，编译好的着色器加固定配置）。
2. 建一块 640×360 的离屏纹理（配置见 Quick Start）。
3. 每帧执行一次渲染（代码见下）：清空画布 → 画一个覆盖全屏的三角形 → 结果存进纹理；整段命令装进一个命令缓冲（command buffer，GPU 命令的容器）提交执行。
4. 每 30 帧抽检一次：`getBytes`（把 GPU 纹理的一个区域拷回 CPU 内存）整帧回读，统计非黑像素占比，低于 50% 判为无效帧。

第 3 步的代码，重点在渲染目标怎么指向离屏纹理：

```swift
let pass = MTLRenderPassDescriptor()
pass.colorAttachments[0].texture = tex
pass.colorAttachments[0].loadAction = .clear
pass.colorAttachments[0].storeAction = .store
pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

guard let cb = queue.makeCommandBuffer(),
      let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { continue }
enc.setRenderPipelineState(pipeline)
enc.setFragmentBytes(&t, length: 4, index: 0)
enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
enc.endEncoding()
cb.commit(); cb.waitUntilCompleted()
```

- `colorAttachments[0].texture = tex`：渲染目标从默认的屏幕换成离屏纹理，这是离屏渲染的全部秘密。
- `loadAction = .clear` + `clearColor`：画每帧前先把画布清成黑色，避免上一帧残影。
- `storeAction = .store`：画完把结果写回纹理。没有这一步，GPU 画完即丢弃。
- `drawPrimitives(..., vertexCount: 3)`：只画一个三角形。三个顶点坐标是 (-1,-1)、(3,-1)、(-1,3)，在裁剪空间（clip space，坐标超出 [-1,1] 的部分会被裁掉）里张开成一个盖满整屏的大三角形，一次 draw 就让片元着色器跑遍全部 640×360 像素。
- `setFragmentBytes(&t, ...)`：把当前帧时间传给片元着色器，着色器用它让画面随帧滚动，90 帧才互不相同。

你在预期输出里看到的 fps，就来自这个循环：每帧"渲染 → 等待 → （抽检帧）回读"，90 帧除以总耗时。

## Pitfalls & Q&A

坑：回读到的全是黑色或旧帧。现象是 `getBytes` 拿到的像素不符合刚画的内容。原因是 GPU 命令异步执行，提交后立刻回读，绘制可能还没跑。

解法是 `commit` 后先 `waitUntilCompleted()` 再回读；`.shared` 存储模式（CPU 与 GPU 共享同一块内存）没有自动的 GPU 到 CPU 同步，必须显式等待。

坑：纹理 usage 漏配 `.renderTarget`。现象是创建渲染管线或编码渲染命令时报校验错误。原因是这块纹理没被声明为"可作画布"。解法是按 Quick Start 的三行配置声明 usage，需要什么权限就开什么。

Q：为什么叫帧序列导出，却没有生成 mp4 文件？本实验只验证管线前半段"画得出来、读得回来"。把像素编成 mp4 需要 VideoToolbox 编码器（源码注释与输出提示里写的 AVAssetWriter + VTCompressionSession），那是独立的下一段管线。

Q：抽检为什么整帧回读而不是像实验 08 那样读一个像素？这里要判断"有效像素占比"，必须看过整帧；90 帧里只抽 3 帧（`frame % 30 == 0`），开销可控。

深入：生产环境怎么减少回读开销？逐帧 `waitUntilCompleted` 会让 CPU 频繁空等 GPU。常见做法是把多帧的回读合并成批，或用 blit encoder（Metal 里专管 GPU 内存拷贝的命令编码器）先把多帧集中到一块缓冲区，再一次回读，减少 CPU 等待的次数。
