# ⚡️ Metal 项目 7：绘制圆形（07_Circle.swift）

> 所属系列：《Apple Metal 30 小项目学习清单》第二阶段「着色器特效」（项目 7/30）
> 代码：`0x_learn_metal/LearnMetal/LearnMetal/Programs/07_Circle.swift`
> 目标：用 `length` + `smoothstep` 在片元着色器里画出一个**带抗锯齿毛边的干净圆形**。

---

## 一、领域知识：用距离场画形状

把一个形状画在屏幕上，除了顶点几何，还有一种更"着色器原生"的方法——**隐式距离场（SDF）**：

> 为每个像素算一个数：**这个像素离圆的边界有多远**。然后按距离决定它是"圆内"、"圆外"还是"边缘"。

圆形的距离公式极简：点到圆心的 `length`（长度）。

```
圆内：length(uv - center) < radius
圆上：length(uv - center) = radius
圆外：length(uv - center) > radius
```

逐像素执行这个不等式，就得到圆的形状——完全不需要任何三角形逼近。

### 1. 先做 UV 平移与缩放

```metal
float2 uv = in.texCoord;                 // [0,1]²
float2 center = float2(0.5, 0.5);        // 圆心放画面中央
float radius = 0.35;                     // 圆半径
```

`uv - center` 把坐标系移到圆心，`length` 就得到"到圆心的距离"。

### 2. 核心一行：距离判断

```metal
float dist = length(uv - center);
```

### 3. `smoothstep` —— 抗锯齿的灵魂

如果直接 `if (dist < radius) 圆内 else 圆外`，边缘会是生硬的锯齿（像 06 的棋盘）。用 1 个像素宽的 **软过渡带** 做平滑：

```metal
float smoothness = 0.02;   // 边缘软化宽度
float circle = 1.0 - smoothstep(radius - smoothness, radius + smoothness, dist);
```

`smoothstep(edge0, edge1, x)` 的工作方式：

- `x <= edge0` → 0.0
- `x >= edge1` → 1.0
- 中间 → 三次式平滑插值（0→1 无断点）

把半径两侧各扩 `smoothness`，`dist` 落在这个区间内的像素就会得到 0→1 的连续过渡，边缘看起来"软"且没有锯齿。`1 - ` 反转方向，使圆内 = 1、圆外 = 0。

### 4. 用 mix 上色

```metal
float3 bgColor    = float3(0.1, 0.1, 0.1);   // 深灰背景
float3 circleColor = float3(1.0, 0.6, 0.2);  // 橙色圆
float3 color = mix(bgColor, circleColor, circle);
```

---

## 二、代码架构

```
runCircle()
└── CircleViewController (MTKViewDelegate)
├── viewDidLoad     Metal → MTKView(灰底) → 队列 → 管线 → 全屏四边形
├── setupPipeline() circle_vertex_main + circle_fragment_main
├── setupVertexData()  6 顶点（pos + uv）
└── draw(in:)       drawPrimitives(.triangle, 6) → present
```

片元着色器 `circle_fragment_main` 完整逻辑：

```metal
fragment float4 circle_fragment_main(CircleVertexOut in [[stage_in]]) {
    float2 uv = in.texCoord;
    float2 center = float2(0.5, 0.5);
    float radius = 0.35;
    float dist = length(uv - center);

    float smoothness = 0.02;
    float circle = 1.0 - smoothstep(radius - smoothness, radius + smoothness, dist);

    float3 bgColor = float3(0.1, 0.1, 0.1);
    float3 circleColor = float3(1.0, 0.6, 0.2);
    float3 color = mix(bgColor, circleColor, circle);
    return float4(color, 1.0);
}
```

**整段代码才 ~10 行，却画出了一个完美的抗锯齿圆。** 这就是"片元着色器 = 数学画布"最直观的体现。

---

## 三、领域知识：为什么 `smoothstep` 让距离场变干净

锯齿的本质是"采样刚好落在边界的半像素处"，硬二值必然产生锯齿。`smoothstep` 把边界附近 0→1 的开关变成连续斜坡：

- 对 GPU 而言，像素是**离散采样点**，一条 45° 边界不可能用像素完美表示——只能靠"半透明模糊"来骗过眼睛。
- 过渡带把那一个像素的"全有或全无"变成"部分有"，视觉效果就是平滑边缘。

这套"distance → smoothstep → mix"三位一体，是整个 SDF 家族（圆、圆环、方、三角、甚至字体）的祖传范式。

---

## 四、运行方式

```swift
// main.swift
print("=== Running Circle Drawing ===")
runCircle()
```

800×600 窗口中，深灰背景中央是一个橙色圆形，**边缘光滑无锯齿**。

---

## 五、延伸思考

- **`smoothstep` 与 `step` 的关系**：`step` 是 0/1 硬开关，`smoothstep` 是 0→1 软开关。06 棋盘用 step（要硬边），07 圆用 smoothstep（要软边）——同一个插值家族，需求决定形式。
- **`mix` 与透明 alpha**：其实可以 `float4(lerpedColor, circle)` 让圆边缘半透明。不用 `mix` 而直接混合背景，是因为我们总有一个确定的 bgColor，`mix` 更直观。
- **试试变体**：把 `radius` 改成 `length(uv-center) < radius ? radius - length(...) : 0.0` 能得到**渐变实心圆**；乘上 `uv` 的方向得到**径向渐变**；SDF 再加上取模/对称就能组合出星形、花朵——项目 10 的「线条与分形图案」正是这些技巧的延续。
- 圆是最简单的 SDF。下一项目 8 用 `mix` 做渐变——把那根"到圆心的距离"换成缩放后的 uv 坐标，就得到彩色的渐变背景。

---

*系列：《Apple Metal 30 小项目》· 第二阶段：着色器特效（6-9）→ 项目 8：颜色渐变*