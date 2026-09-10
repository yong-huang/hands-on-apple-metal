# ⚡️ Metal 项目 6：棋盘格图案（06_ChessBoard.swift）

> 所属系列：《Apple Metal 30 小项目学习清单》第二阶段「着色器特效」（项目 6/30）
> 代码：`0x_learn_metal/LearnMetal/LearnMetal/Programs/06_ChessBoard.swift`
> 目标：**在片元着色器里算出一个棋盘格**——第一次让颜色不再来自顶点，而是由 GPU 逐像素计算。

---

## 一、领域知识：全屏四边形 + 片元着色器

阶段一画三角形/矩形靠的是**顶点颜色插值**。而阶段二走上了另一条路：

> **只画一个铺满屏幕的四边形，然后用片元着色器决定每个像素的颜色。**

这样"画的内容"完全由数学公式决定，一条 `drawPrimitives` 就能表达无数种图案。这让片元着色器变成真正的"画笔"，也是现代 Shader Toy / 特效的基础。

### 1. 全屏四边形（Fullscreen Quad）

6 个顶点、2 个三角形拼成一个 `[-1,1]²` 的大四边形，顶点多带一个 **UV（纹理坐标）**：

```
(-1, 1)→uv(0,1)   ( 1, 1)→uv(1,1)
(-1,-1)→uv(0,0)   ( 1,-1)→uv(1,0)
```

```swift
struct ChessboardVertex {
    var position: SIMD3<Float>
    var texCoord: SIMD2<Float>
}
```

顶点着色器是"纯直通"：位置原样输出，UV 原样传给片元着色器。**所有的魔法都发生在 fragment**。

### 2. 棋盘格的数学：`fract` + `step`

棋盘格的核心问题：**如何把连续空间切成黑白相间的格子？**

**第 1 步 —— 放大与重复：**
```metal
float2 coord = in.texCoord * 8.0;     // 把 [0,1] 拉伸成 [0,8]
float2 pattern = fract(coord);        // 只保留小数部分 → 每个格子内都是 [0,1)
```

`fract(x) = x - floor(x)` 让坐标在每个格子内"从头开始"，从而产生重复。

**第 2 步 —— 黑白二值化：**
```metal
pattern = step(0.5, pattern);         // 格子一半黑一半白
// step(edge, x)：x >= edge 时为 1.0，否则 0.0
```

**第 3 步 —— 奇偶棋盘（关键）：**
```metal
float2 chess = step(0.5, fract(coord * 0.5));   // 对放缩后的坐标再取模
chess = fract(chess * 0.5);
chess = step(0.5, chess);
float checker = chess.x * chess.y;    // 相邻格子黑白翻转
```

也可以写成更直白的整数奇偶法：
```metal
uint cellX = uint(floor(coord.x));
uint cellY = uint(floor(coord.y));
bool black = ((cellX + cellY) % 2) == 0;
```
两格只要 (x+y) 一奇一偶，颜色就交错——这就是棋盘格的本质。

**第 4 步 —— 映射成颜色：**
```metal
float3 color = mix(float3(0.1, 0.1, 0.1), float3(0.9, 0.9, 0.9), checker);
```

---

## 二、代码架构

```
runChessboard()
└── ChessboardViewController (MTKViewDelegate)
├── viewDidLoad      Metal → MTKView(黑底) → 队列 → 管线 → 全屏四边形
├── setupPipeline()  chessboard_vertex_main + chessboard_fragment_main
├── setupVertexData() 6 顶点（pos + uv）→ vertexBuffer
└── draw(in:)        drawPrimitives(.triangle, 6 顶点) → present
```

着色器函数就两个：
- `chessboard_vertex_main`：直通 position + uv（重复 N 次的样板）
- `chessboard_fragment_main`：`[[stage_in]]` 收 uv，`fract/step/mix` 算棋盘色

`draw(in:)` 只需一次 `drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)`——**全部 262144 个像素的颜色，都由片元着色器逐个算出来**。

---

## 三、领域知识：`step` fork 的正确姿势

`color = mix(dark, light, checker)` 中 `checker` 是 0/1 二值：

- `mixed = mix(a, b, t) = a * (1-t) + b * t`
- t=0 → 纯深灰 `(0.1,0.1,0.1)`，t=1 → 纯浅灰 `(0.9,0.9,0.9)`

**这和 08 用 `smoothstep` 得到渐变 t 是同一套**：mix 是"按 t 插值"，t 的形状决定是硬边（棋盘）还是软边（渐变/抗锯齿）。

---

## 四、运行方式

```swift
// main.swift
print("=== Running Chessboard Pattern ===")
runChessboard()
```

窗口标题 `Chessboard Pattern (Fragment Shader)`，画面是 8×8 的 16 阶棋盘格，格子黑/白分明、无抗锯齿。

---

## 五、延伸思考

- **为什么用 UV 而不用 NDC 坐标？** UV `[0,1]²` 方向明确（v 向上）、长度标准化，做 tile 和采样都顺手；很多特效 Directly 用 `uv`（如在 07 里还拿它当"像素坐标"算圆形）。
- **`fract` + `step` 的组合就是"空间重复"的万能钥匙**，后面做线条纹理（项目 10）、网格、极坐标图案都复用。
- 棋盘格是纹理太贵时的廉价替代；也常见于纹理坐标可视化调试——把 UV 贴图的问题一眼看穿。
- **下一个项目 07** 用 `length` 算圆，把"逐像素几何距离"玩到极致——从这一课起，"片元着色器 = 数学画布"的思维就彻底打开了。

---

*系列：《Apple Metal 30 小项目》· 第二阶段：着色器特效（6-9）→ 项目 7：绘制圆形*