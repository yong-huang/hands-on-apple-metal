# ⚡️ Metal 项目 3：渲染一个三角形（03_Triangle.swift）

> 所属系列：《Apple Metal 30 小项目学习清单》第一阶段「Metal 基础入门」（项目 3/30）
> 代码：`0x_learn_metal/LearnMetal/LearnMetal/Programs/03_Triangle.swift`
> 目标：第一次在屏幕上画出图形——红/绿/蓝三色渐变三角形。

---

## 一、领域知识：渲染一个三角形需要的 6 样东西

`03_Triangle.swift` 的注释用"画板"做了很好的类比：

| Metal 对象 | 类比 |
|:---|:---|
| `MTKView` | 画板框架——管理整个绘画流程 |
| `MTKView.currentDrawable` | 纸张/画布——一块真实的 GPU 纹理 |
| `draw(in:)` + encoder | 你画画的过程 |
| `MTLClearColor` | 纸的底色（清屏色） |

### 1. `MTKView` —— 渲染上下文

MetalKit 提供的视图，替你管理：与 `MTLDevice` 的绑定、drawable 的创建、窗口尺寸变化，以及每帧回调 `draw(in:)`：

```swift
metalView = MTKView(frame: view.bounds, device: device)
metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
metalView.delegate = self   // 实现 MTKViewDelegate.draw(in:)
```

### 2. 渲染管线（Pipeline）—— GPU 流水线

```
vertex(顶点) → 光栅化 → fragment(片元/像素) → 帧缓冲
```

`MTLRenderPipelineState` 把"顶点着色器 + 片元着色器 + 像素格式"提前打包，三步创建：

```
① 写着色器源码（Swift 字符串内嵌 MSL）
② device.makeLibrary() 编译 → library.makeFunction() 取函数
③ MTLRenderPipelineDescriptor 打包 → makeRenderPipelineState() 生成状态
```

**顶点着色器**（每个顶点调一次，输出裁剪坐标 `[[position]]` 和颜色）：

```metal
vertex VertexOut vertex_main(
    constant VertexIn *vertices [[buffer(0)]],   // 顶点缓冲
    uint vertexID [[vertex_id]]                  // 当前顶点下标
) {
    VertexOut out;
    out.position = float4(vertices[vertexID].position, 1.0);
    out.color    = vertices[vertexID].color;
    return out;
}
```

**片元着色器**（每个像素调一次，直接返回颜色）：

```metal
fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}
```

顶点之间的颜色在光栅化阶段**自动插值**——这就是三色渐变三角形的来源：三个顶点给红/绿/蓝，中间像素平滑过渡。

### 3. 顶点数据与 NDC 坐标

三角形定义在 **NDC（标准化设备坐标）**，范围 `[-1,+1] × [-1,+1]`：

```
( 0.0,  0.5) → 红(顶部)
(-0.5, -0.5) → 绿(左下)
( 0.5, -0.5) → 蓝(右下)
```

包装成结构体整包上传到 `MTLBuffer`：

```swift
struct Vertex { var position: SIMD3<Float>; var color: SIMD4<Float> }

vertexBuffer = device.makeBuffer(
    bytes: vertices,
    length: vertices.count * MemoryLayout<Vertex>.stride,
    options: .storageModeShared    // CPU/GPU 共享存储，统一内存下无需额外同步
)
```

---

## 二、代码架构

```
runTriangle()         顶层入口：NSApplication + AppDelegate
└── AppDelegate       创建 800×600 窗口 → contentViewController
TriangleViewController (NSViewController + MTKViewDelegate)
├── viewDidLoad       五步 Setup：Metal → MTKView → 命令队列 → 管线 → 顶点
├── setupPipeline()   编译着色器，打包渲染管线
├── setupVertexData() 定义 3 顶点 → MTLBuffer
└── draw(in:)        每帧：取 drawable → 编码器 → 绑定 → 画 → present + commit
```

`draw(in:)` 是每一帧的"绘画动作"，也是此后所有渲染项目的主舞台：

```swift
func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable,
          let renderPassDescriptor = view.currentRenderPassDescriptor else { return }

    let commandBuffer = commandQueue.makeCommandBuffer()!
    let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!

    renderEncoder.setRenderPipelineState(pipelineState)
    renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

    renderEncoder.endEncoding()
    commandBuffer.present(drawable)   // 把画好的内容呈现到屏幕
    commandBuffer.commit()
}
```

**关键一步：`commandBuffer.present(drawable)`**——它告诉 GPU"渲染完成后把这个 drawable 呈现到窗口"。这是项目 2 里没有的部分。

---

## 三、为什么能"渐变"而不是三块纯色

颜色（`color`）是**逐顶点属性**，从顶点着色器经由 `[[stage_in]]` 传到片元着色器。GPU 在光栅化阶段对每个像素做**重心坐标插值**：越靠近哪个顶点，颜色越像哪个顶点。`return in.color` 看似"直接返回顶点颜色"，实际上每个像素拿到的都是插值后的颜色。

> 顶点着色器用 `[[vertex_id]]` 逐个取顶点，片元着色器用 `[[stage_in]]` 接收插值——两条数据通路是理解着色器架构的钥匙。

---

## 四、运行方式

```swift
// main.swift
print("=== Running Triangle Rendering ===")
runTriangle()
```

运行后看到 800×600 窗口、深灰背景上的红绿蓝渐变三角形即达标。

---

## 五、延伸思考

- **`setupPipeline` 三步为什么在 `viewDidLoad` 一次性做完？** 编译着色器很贵，应在启动时做一次、渲染时反复复用（pipeline state 是真正复用的核心资源）。
- **`drawPrimitives(.triangle, vertexCount: 3)`** 是最原始的"给两个数就画"接口；高频场景更适合"给一组索引画大量三角形"——这正是项目 4：索引缓冲。
- 想让三角形动起来？需要把"每帧变化的矩阵"传给 GPU，这就是项目 5 的 Uniform Buffer。

---

*系列：《Apple Metal 30 小项目》· 第一阶段：基础入门（1-5）→ 项目 4：渲染彩色矩形*