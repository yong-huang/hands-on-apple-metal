# 04 · 索引缓冲画矩形：4 个顶点拼 2 个三角形

> 上一篇的三角形只用了 3 个顶点，谁也不重复。
> 但矩形 = 2 个三角形 = 6 个顶点，其中 2 个完全重复——顶点一多（大模型动辄百万顶点），这种浪费不可接受。
> 本实验引入索引缓冲：顶点只存一份，靠"点名册"决定拼装顺序。

## 1. 为什么需要它

GPU 画图元的单位是三角形，而相邻三角形几乎总要共享顶点。索引缓冲把"顶点数据"与"顶点使用顺序"解耦：顶点缓冲去重存数据，索引缓冲存 `0,1,2,2,3,0` 这样的序号序列。真实的 3D 网格里一个顶点平均被 6 个三角形复用，索引能省下大量显存与顶点着色器调用。

## 2. 总览：核心机制一图看懂

![索引缓冲数据流](images/rectangle.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/04_rectangle/images/rectangle.html)（或本地打开 [`images/rectangle.html`](images/rectangle.html)）。

顶点缓冲（4 个四角）与索引缓冲（6 个序号）汇入 `TriangleStrip` 组装器 → 折叠出 2 个三角形 → 填充成四色矩形。一句话心智模型：**索引是顶点的点名册，每 3 个连续索引唱名出一个三角形**。

## 3. 快速开始

```bash
./rectangle.sh               # 一条龙：build → observe → clean
AUTO_QUIT=6 ./rectangle.sh observe   # 6 秒自动退出
```

观察要点：窗口里一个矩形，四个角各一色（红/绿/蓝/黄），颜色在矩形内部平滑过渡——顶点色插值在更大面积上的重演。

验证方法：把索引序列改成 `[0,1,2, 2,3,0]` 的任意旋转（如 `[1,2,3, 3,0,1]`），画面应该不变——这正是"索引只是顺序"的证明。

## 4. 核心概念

### 4.1 两种拼装模式

| 模式 | 画 N 个三角形需要 | 适用 |
|:---|:---|:---|
| `.triangle` | 3N 个索引 | 互不相连的散三角形 |
| `.triangleStrip` | N+2 个索引 | 条带相连的三角形（本实验） |

TriangleStrip 的折叠规则：第 n 个三角形取索引 `n, n+1, n+2`，相邻三角形共享一条边。本实验 `[0,1,2,2,3,0]` 中间两个 `2` 连用，是条带转向的小技巧（snake order）。

### 4.2 索引的数据类型

索引缓冲里存 `uint16`（最多 65536 顶点）或 `uint32`。顶点数少于 6.5 万时用 `uint16` 省一半带宽——模型网格优化的常识。

### 4.3 绘制调用变了

用索引后，`drawPrimitives` 换成 `drawIndexedPrimitives(type:indexCount:indexType:indexBuffer:)`——GPU 先查索引再取顶点，vertex shader 对被复用的顶点可能只跑一次（有顶点缓存时）。

### 4.4 易错点

- 索引越界（指向不存在的顶点）是未定义行为，可能画出垃圾图形也可能崩溃。
- 条带里相邻三角形绕序自动翻转——开启背面剔除（cull mode）时要注意奇偶朝向。

## 5. 关键 API 与字段

```swift
// 索引缓冲：6 个 uint16 序号，点名 4 个顶点
let indices: [UInt16] = [0, 1, 2, 2, 3, 0]
let indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * 2)

// 条带模式绘制：indexCount 是"索引数"（6），不是顶点数（4）
encoder.drawIndexedPrimitives(
    type: .triangleStrip, indexCount: indices.count,
    indexType: .uint16, indexBuffer: indexBuffer, indexBufferOffset: 0)
```

为什么 4 顶点 + 6 索引就够了：三角形 1 用顶点 0-1-2，三角形 2 用顶点 2-3-0——共享了对角线上的 2 和 0，没有顶点被重复存储。

## 6. 文件结构

```
04_rectangle/
├── README.md                     # 本文档
├── rectangle.sh                  # 主演示脚本：build → observe → clean（AUTO_QUIT 自动退出）
├── main.swift                    # 入口包装：调用 runRectangle()，开窗口
├── rectangle.swift               # 实验程序本体：4 顶点 + 6 索引 + TriangleStrip
└── images/
    ├── rectangle.dataflow.json   # 图源（Typed JSON IR）
    ├── rectangle.html            # 交互版数据流图（浏览器打开）
    └── rectangle.svg             # 双主题矢量版（README 内嵌）
```

## 7. 深入要点

- **索引缓冲解决什么问题？** 顶点复用：数据存一份、顺序另存，省显存省 vertex 调用；大网格的标配。
- **TriangleStrip 与 Triangle 的取舍？** Strip 连续图元只要 N+2 个索引，适合条带状网格；Triangle 灵活适合散片，多花 3N 个索引。
- **indexCount 与 vertexCount 的区别？** 前者是索引缓冲里序号的个数（决定画几个三角形），后者是顶点缓冲的容量；`drawIndexedPrimitives` 用前者。
- **uint16 还是 uint32 索引？** 顶点 <65536 用 uint16，带宽减半；大网格或嫌重建麻烦直接 uint32。

## 8. 总结

矩形出炉，顶点复用的思想到手——这是所有网格建模的基石。但画面还是静止的：下一篇让三角形转起来，认识 CPU 每帧给 GPU 递话的通道——Uniform Buffer。

→ 下一篇：[05 · 旋转动画三角形](../05_animated_triangle/README.md)
