# ⚡️ Metal 项目 9：纹理贴图（09_Texture.swift）

> 所属系列：《Apple Metal 30 小项目学习清单》第二阶段「着色器特效」（项目 9/30）
> 代码：`0x_learn_metal/LearnMetal/LearnMetal/Programs/09_Texture.swift`
> 目标：把一张**程序生成的棋盘纹理**贴到全屏四边形上——首次接触 `MTLTexture`、`MTLSamplerState` 与 GPU 采样。

---

## 一、为什么要"纹理"

项目 3-8 里，颜色要么来自顶点插值，要么由片元着色器现场计算。但真实美术素材是像素图片：照片、UI、模型贴图。把它们送进 GPU 的标准载体就是 **纹理（Texture）**。

`MTLTexture` 本质是一块 **GPU 内存里的 2D 像素数组**（宽×高 的 RGBA 数组）。片元着色器通过 UV 坐标从中**采样**出颜色。

```
UV 坐标 (0,0)-(1,1)  →  纹理采样  →  纹素(texel)颜色  →  像素输出
```

---

## 二、代码架构：两块拼图

### 1. `loadTexture()` —— 造一张纹理（CPU→GPU）

本项目不读图片文件，而是**程序生成**：用 CPU 写出一块 256×256 棋盘图案，再上传给 GPU。

```swift
func loadTexture() {
    // ① 描述纹理格式
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba8Unorm,
        width: 256, height: 256, mipmapped: false)

    // ② 由 device 创建真正的 GPU 纹理
    guard let texture = device.makeTexture(descriptor: textureDescriptor) else { ... }

    // ③ CPU 逐像素填色：32×32 棋盘格（黑格/白格交替）
    let squareSize = 32
    for y in 0..<256 { for x in 0..<256 {
        let isBlack = ((x / squareSize) + (y / squareSize)) % 2 == 0
        // 按 isBlack 写入 RGBA 四个分量
    }}

    // ④ 整块上传到 GPU
    let region = MTLRegionMake2D(0, 0, 256, 256)
    texture.replace(region: region, mipmapLevel: 0,
                    withBytes: pixels, bytesPerRow: stride)  // stride = 256 * 4 字节

    self.texture = texture
}
```

**关键点：**
- `.rgba8Unorm`：每像素 4 字节（R/G/B/A 各 8bit，UNORM=0-255 映射到 0.0-1.0）
- `bytesPerRow` 必须告诉 GPU **每行的字节数**，这是跨行寻址的依据，少了必出错
- 纹理的格式、分辨率在 `MTLTextureDescriptor` 里定死，之后再无退路

### 2. 采样器 —— "怎么取颜色"的规则

`MTLTexture` 只管"放颜色"，**怎么取**由 `MTLSamplerState` 决定。片元着色器用 UV 去纹理取样，取样器定了三件事：

```metal
struct TextureVertexOut { float4 position [[position]]; float2 texCoord; };

fragment float4 texture_fragment_main(
    TextureVertexOut in [[stage_in]],
    texture2d<float> texture [[texture(0)]],     // 绑定纹理
    sampler sampler2D [[sampler(0)]]             // 绑定采样器
) {
    float4 color = texture.sample(sampler2D, in.texCoord);
    return color;
}
```

**`texture.sample(sampler, uv)` 是纹素访问的心脏**——它代替了"手写取值逻辑"，把过滤、寻址、归一化全部交给硬件/驱动，一行解决。CPU 侧创建采样器：

```swift
let samplerDescriptor = MTLSamplerDescriptor()
samplerDescriptor.minFilter = .linear       // 缩小过滤
samplerDescriptor.magFilter = .linear       // 放大过滤
samplerDescriptor.sAddressMode = .clampToEdge
samplerDescriptor.tAddressMode = .clampToEdge
let sampler = device.makeSamplerState(descriptor: samplerDescriptor)!
renderEncoder.setFragmentSamplerState(sampler, index: 0)
```

- **`.linear`**：双线性插值——采样点落在两个纹素之间时取加权平均，放大后不糊成马赛克
- **`.clampToEdge`**：UV 超出 [0,1] 时用边缘纹素钳住，不重复也不透明

---

## 三、为什么不需要"顶点颜色"了

对比项目 3（顶点带颜色）和本项目（顶点带 `texCoord`）：

| | 项目 3 | 项目 9 |
|:---|:---|:---|
| 顶点属性 | position + **color** | position + **texCoord** |
| 颜色来源 | 顶点插值 | 纹理采样 |
| 片元着色器 | `return in.color` | `texture.sample(...)` |
| 数据通量 | 顶点数据定死颜色 | 一张纹理养活无数像素 |

纹理让"色彩"与"几何"解耦：同样的三角形，换一张贴图就完全变样。这正是真实 Demo、3D 模型贴图、UI 素材的统一管线。

---

## 四、代码架构

```
runTexture()
└── TextureViewController (MTKViewDelegate)
├── viewDidLoad     Metal → MTKView → 队列 → loadTexture() → setupPipeline → setupVertexData
├── loadTexture()   程序生成棋盘像素 → makeTexture → replace 上传
├── setupPipeline() 编译 texture shaders + 采样器
├── setupVertexData() 6 顶点（pos + uv）
└── draw(in:)
    ├── setVertexBuffer(vertexBuffer, 0)
    ├── setFragmentTexture(texture, index: 0)
    ├── setFragmentSamplerState(sampler, index: 0)
    └── drawPrimitives(.triangle, 6) → present
```

注意 `draw(in:)` 多了两行绑定：`setFragmentTexture` 把纹理贴到片元着色器的 `[[texture(0)]]`，`setFragmentSamplerState` 把采样器贴到 `[[sampler(0)]]`。**绑定槽序号必须与着色器里的注解一致**，这是 CPU 侧与 GPU 侧沟通的暗号。

---

## 五、运行方式

```swift
// main.swift
print("=== Running Textured Quad ===")
runTexture()
```

窗口标题 `Texture and Sampler `，画面是 8×8 的棋盘纹理平铺满屏，格子边缘因 `magFilter = .linear` 轻微软化。

---

## 六、延伸思考

- **采样器为什么不是纹理的属性**：同一张纹理，可以"近邻不糊"（新闻图缩略）也可以"线性平滑"（游戏地砖），把策略参数抽出来做独立对象，复用纹理、自由换策略。
- **`rgba8Unorm` 是内存冠军**：8bit/通道省空间、兼容性好；需要更高精度（HDR、深度）时再换 `rgba16Float` 等，选型由数据和用途决定。
- **下一步**：阶段二收官。项目 10-14（线条纹理、极坐标、变换组合等）会在本项目基础上，把 `texture.sample` 换成**逐像素数学纹理**——你的全屏四边形脚手架 + 采样器 + 数学片元，已经能玩出整片宇宙。
- 真正的照片纹理、多纹理（法线/金属贴图）要等阶段五、六，但"纹理管线"这套心智模型（描述符→生成→上传→采样器→片元采样）今天已经完整了。

---

*系列：《Apple Metal 30 小项目》· 第二阶段：着色器特效（6-9）→ 下一阶段：着色器实战（10-14）*