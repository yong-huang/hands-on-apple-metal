# 22 · 实例化渲染：一次 draw 画 400 个
> 画 400 个物体，一定要提交 400 次 draw call（CPU 向 GPU 提交的一次绘制命令）吗？实例化渲染把"同一几何的 N 份拷贝"压成一次绘制：几何存一份，每份的差异（位置、颜色、大小）存成轻量参数。读完本篇你能用实例缓冲加 `[[instance_id]]` 把 400 次提交降为 1 次，并理解游戏优化里"Draw Call 预算"这个词的由来。

## Background

不用实例化时，画 400 个相同的物体有两条老路：要么逐个提交 400 次绘制命令——每次设置参数、调用一次 draw；要么在 CPU 侧把 400 份几何拼成一个大缓冲，一次画完。

两条路各有代价。draw call 本身有 CPU 侧成本：每次提交都要做状态验证、走一遍图形驱动，GPU 本来能吃下更多三角形，CPU 的提交速度却先撑不住——万级物体时，先崩溃的是 CPU。拼大缓冲则把几何焊死了：400 份几何逐份复制进显存，想改某个物体的位置或颜色就得动几何数据。

实例化渲染的解法是把"形状"和"差异"分开存：同一几何只存一份，每份拷贝的位置、颜色、大小存成一行轻量参数；一次绘制命令带上份数，GPU 自己循环生成所有拷贝。这是植被、人群、粒子网格这类场景的标准做法。

## What

实例化渲染（instanced rendering）是 GPU 绘制的一种模式：一次绘制同时画出同一几何的 N 份拷贝。本实验用 Metal——苹果的 GPU 编程框架——把一个三角形画 400 份。

几何是 3 个顶点（构成三角形的坐标点），存一块顶点缓冲；差异是每实例的位置偏移、颜色、大小，存一块实例缓冲。实例缓冲与顶点缓冲一样是普通 buffer（GPU 显存里连续的原始数据区域），只是语义上"每实例一行"。

一句话心智模型：**`[[instance_id]]` 是"我是第几份拷贝"的自查**。可以把实例化想象成复印：原件（几何）只有一份，每张复印件（实例）带不同的位移、缩放和颜色批注。但和复印不同的是：这些批注存在可随时改写的缓冲里，每帧都能换——差异来自数据，不来自新的几何。

本实验的 400 份实例按 20×20 网格铺开，颜色随网格位置渐变，大小有固定种子的随机抖动。

## When to Use

这一节给判断力：什么样的场景值得把多次绘制压成一次实例化。

典型场景：

- 植被、人群、石块：同一个模型要铺成千上万份，位置颜色各不相同。
- 粒子网格、碎片、弹壳：小几何大量重复出现。
- 需要每帧调整每个副本的位置或颜色：只更新实例缓冲即可，几何不动。

何时不用：

- 拷贝只有几个：多次 draw 的开销可以接受，代码更直白。
- 物体几何各不相同：实例化只复制"同一几何"，帮不上忙；静态场景考虑合批（batching，把多个不同几何预先拼进一个大缓冲一次画完）。
- 每实例需要顶点级的不同细节：那是几何差异，不是参数差异，实例化覆盖不了。

| 方案 | 差异 | 什么时候选它 |
|---|---|---|
| 多次 draw（每物体一次） | 直观；CPU 提交开销随物体数线性上涨 | 物体少、各自差异大 |
| 合批（batching） | 一次 draw 画完，但几何固化，逐物体参数难动态改 | 静态场景（不动的地形、建筑） |
| 实例化（本实验） | 几何一份 + 轻量逐实例参数；一次 draw，参数可动态更新 | 同一几何的 N 份拷贝：植被、人群、粒子网格 |
| 引擎内置 instancing（Unity / Unreal 的 GPU Instancing） | 原理相同，引擎自动管理缓冲与提交 | 用游戏引擎开发时 |

## Quick Start

前置条件：macOS 加 Xcode 的 Swift 工具链。在 `metal/22_instancing/` 目录下运行：

```bash
./instancing.sh               # 一条龙
AUTO_QUIT=6 ./instancing.sh observe
```

控制台输出（真实输出）：

```
几何: 1 个三角形 × 400 个实例 → 每帧只有 1 次 draw call
```

窗口显示 20×20 的三角形阵列，颜色按网格位置渐变。验证方法：`drawPrimitives` 的 `instanceCount` 改成 100，画面只剩 100 个——阵列规模确实由这一个参数驱动。

绘制侧代码在 `instancing.swift` 的 `draw(in:)` 里：

```swift
enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)     // 几何
enc.setVertexBuffer(instanceBuffer, offset: 0, index: 1)   // 实例
enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 400)
```

这段在做什么：把几何缓冲和实例缓冲分别绑到槽位 0 和 1，然后用一次 draw 声明"3 个顶点 × 400 份实例"。GPU 会把顶点着色器（vertex shader，为每个顶点执行一次的 GPU 函数）调用 vertexCount × instanceCount = 1200 次。

## How It Works

按一帧的执行路径展开：两块缓冲怎么分工，顶点着色器怎么用两个编号取数，输出为什么只有一次 draw call。

**两块缓冲的分工。** 顶点缓冲只放 3 个顶点——一个中心在原点的单位三角形；实例缓冲放 400 行 `InstanceData {offset: float2, color: float4, scale: float}`，即位置、颜色、大小三个自由度。

CPU 侧按 20×20 网格生成 offset，颜色随网格位置渐变，scale 用固定种子伪随机生成（0.8~1.4）。

**顶点着色器是唯一干活的地方。** 核心函数用 Metal 着色语言（Metal Shading Language，简称 MSL，类 C++）编写：

```metal
vertex RasterizerData vertex_main(
    device const Vertex *verts [[buffer(0)]],
    device const InstanceData *instances [[buffer(1)]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]])          // 第几个实例：实例化的灵魂
{
    RasterizerData out;
    InstanceData d = instances[iid];
    // 同一份三角形几何，按实例数据缩放、平移
    float2 p = verts[vid].position * d.scale + d.offset;
    out.position = float4(p, 0.0, 1.0);
    out.color = d.color;
    return out;
}
```

为什么这样写：

- `vid` 来自 `vertex_id`（本顶点在几何内的编号，0~2），`iid` 来自 `instance_id`（本实例的编号，0~399）——两者正交：1200 次着色器调用里，每一对 (vid, iid) 恰好出现一次，组合起来定位"哪个物体的哪个顶点"。
- `p = position * scale + offset` 先缩放后平移：几何以自身中心缩放，再挪到实例自己的位置。
- 颜色直接取自实例数据传给片元着色器（fragment shader，为每个屏幕像素执行一次的函数）——物体间的差异全部来自数据，着色器代码里没有任何 if 分支。

**你在输出里看到的一行，来自这里。** "每帧只有 1 次 draw call"对应 `draw(in:)` 里唯一的 `drawPrimitives` 调用；把 `instanceCount` 改成 100 后，`iid` 只会取到 0~99，画面自然只剩前 100 份拷贝——阵列规模完全由这一个参数驱动。

## Pitfalls & Q&A

**物体乱飞、颜色错乱。** 现象：实例位置和颜色对不上号。原因：MSL 侧 `InstanceData` 与 Swift 侧结构体的字段类型或顺序不一致，GPU 按错误的 stride（步长，一行数据占的字节数）取数，数据整体错位。

解法：两侧字段一一对应（float2 offset、float4 color、float scale），改一侧时另一侧同步改。

**画面上只有一个物体。** 现象：400 份实例只画出 1 份。原因：`drawPrimitives` 忘了传 `instanceCount`，该参数默认为 1。解法：显式传 `instanceCount`，并确认它等于实例缓冲的行数。

**实例数上万后性能不再上涨。** 现象：实例加到几万份，帧率不再受益。原因：每实例数据在顶点着色器里被反复读取，实例缓冲本身成为带宽热点。解法：压缩每实例数据——half 精度（16 位浮点，位数减半的浮点格式）、紧打包；更进一步可以让 GPU 侧生成实例数据，CPU 完全不碰。

**实例参数能每帧变吗？** 能。实例缓冲是普通缓冲，每帧更新内容不改变绘制结构——本实验的参数是一次生成后不变，动态更新（比如让整片"植被"随风摆动）只需改写实例数据，绘制命令一行不动。
