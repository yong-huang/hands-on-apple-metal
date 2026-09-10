# ⚡️ Metal 项目 4：渲染一个彩色矩形（04_Rectangle.swift）

> 所属系列：《Apple Metal 30 小项目学习清单》第一阶段「Metal 基础入门」（项目 4/30）
> 代码：`0x_learn_metal/LearnMetal/LearnMetal/Programs/04_Rectangle.swift`
> 目标：用**索引缓冲 + TriangleStraw** 渲染一个四色矩形，理解"如何用最少的顶点数据画最多的三角形"。

---

## 一、领域知识：为什么矩形需要索引缓冲

项目 3 用一个三角形演示了渲染管线。但现实里三角形是海量的，如果用项目 3 的方式（每个三角形独立列 3 个顶点）：

- 两个三角形拼矩形 = **6 个顶点**
- 一个立方体（12 个三角形）= **36 个顶点**
- 一个真正的 3D 模型 = 几十万顶点，其中**大量顶点被多个三角形共用**

**索引缓冲（Index Buffer）** 解决的就是"顶点复用"：

```
顶点缓冲（Vertex Buffer）  存的是一份"不重复的顶点清单"
索引缓冲（Index Buffer）   存的是"用顶点清单里的哪些顶点、按什么顺序组成三角形"
```

这样同样的顶点只存一次，节省内存，也让 `MTLBuffer` 的上传更小、缓存更友好。

---

## 二、坐标与数据设置

矩形 4 个顶点（NDC），颜色取四象限的经典配色：

```
(-0.8,  0.6)  红 | ( 0.8,  0.6)  绿
(-0.8, -0.6)  蓝 | ( 0.8, -0.6)  黄
```

```swift
let vertices: [RectangleVertex] = [
    RectangleVertex(position: SIMD3(-0.8,  0.6, 0), color: SIMD4(1, 0, 0, 1)),   // 左上红
    RectangleVertex(position: SIMD3( 0.8,  0.6, 0), color: SIMD4(0, 1, 0, 1)),   // 右上绿
    RectangleVertex(position: SIMD3(-0.8, -0.6, 0), color: SIMD4(0, 0, 1, 1)),   // 左下蓝
    RectangleVertex(position: SIMD3( 0.8, -0.6, 0), color: SIMD4(1, 1, 0, 1)),   // 右下黄
]

// 索引：4 个下标，配合 triangleStrip 拼出两个三角形
let indices: [UInt16] = [0, 1, 2, 3]

vertexBuffer = device.makeBuffer(bytes: vertices, length: ..., options: .storageModeShared)
indexBuffer  = device.makeBuffer(bytes: indices,  length: ..., options: .storageModeShared)
```

注意：**4 个顶点 + 4 个索引**就画出了矩形，而不用写 6 个顶点。

---

## 三、领域知识：`MTLPrimitiveTypeTriangleStrip`

程序用的是 `drawIndexedPrimitives(type: .triangleStrip, ...)`，也就是**三角形条带**（Triangle Strip）。它与独立三角形（`.triangle`）的区别：

```
.triangle        每次取 3 个独立顶点 → 一个三角形
.triangleStrip   连续"滚动"：第 1 个三角形用 v0,v1,v2，
                 之后每个新顶点 vN 与上两个顶点组成新三角形
```

本项目：索引 `[0, 1, 2, 3]`

```
三角形 1: (v0, v1, v2)
三角形 2: (v1, v2, v3)   ← 复用了 0、1 两个旧顶点的数据（v1, v2）
```

**高效的几何编码方式**：一个矩形只需 `顶点数 + 2` 个三角形周期的索引，退化几何（degenerate）技巧还能用一段索引串起互不连接的图形。

---

## 四、代码架构

`04_Rectangle.swift` 结构与项目 3 几乎一致，唯一区别是绘制调用换成了索引版：

```
runRectangle()                入口
└── RectangleAppDelegate      创建窗口
RectangleViewController (MTKViewDelegate)
├── viewDidLoad               Metal → MTKView → 队列 → 管线 → 顶点&索引
├── setupPipeline()           着色器（rectangle_vertex_main / rectangle_fragment_main）
├── setupVertexAndIndexData() 4 顶点 + 索引缓冲
└── draw(in:)
    └── renderEncoder.drawIndexedPrimitives(
            type: .triangleStrip,
            indexCount: indexCount,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0)
```

着色器与项目 3 完全相同（仅仅改了个函数名）——**顶点位置直通道 + 颜色直通**。这印证了项目 3 的核心结论：只要数据在顶点缓冲里，顶点/片元着色器就能原样消费它。

代码注释里还贴心留了对比：

```swift
// 画独立三角形（不推荐这里用）：
// renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
```

---

## 五、运行方式

```swift
// main.swift
print("=== Running Rectangle Rendering with Index Buffer ===")
runRectangle()
```

运行后 800×600 窗口中，四个象限分别呈现红/绿/蓝/黄四块颜色，中间平滑过渡。

---

## 六、延伸思考

- **`indexType: .uint16` vs `.uint32`**：三角形少于 65,536 个顶点时用 `uint16` 更省内存；大模型需要 `uint32`。这是高模型加载（路线图项目 24）里必踩的点。
- **为什么"索引缓冲 + 条带"叫现代 GPU 的好伙伴？** 顶点缓存命中率更高、带宽更省；后续 3D 立方体、obj 模型加载几乎都用 `drawIndexedPrimitives`。
- 颜色依然靠**顶点插值**：4 个顶点的颜色在矩形内部渐变。想要更细腻的颜色控制，就要走出"顶点色"体系——这正是项目 6 之后片元着色器的主场。

---

*系列：《Apple Metal 30 小项目》· 第一阶段：基础入门（1-5）→ 项目 5：动画旋转的三角形*