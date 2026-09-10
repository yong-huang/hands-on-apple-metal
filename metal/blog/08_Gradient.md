# ⚡️ Metal 项目 8：颜色渐变（08_Gradient.swift）

> 所属系列：《Apple Metal 30 小项目学习清单》第二阶段「着色器特效」（项目 8/30）
> 代码：`0x_learn_metal/LearnMetal/LearnMetal/Programs/08_Gradient.swift`
> 目标：用 `smoothstep` + `mix` 在片元着色器里渲染一段平滑流畅的彩色渐变。

---

## 一、领域知识：`mix` 与 `smoothstep` 的量化学表达

项目 6/7 里，`mix(a, b, t)` 的 t 分别是 `step`（硬边）和 `smoothstep`（软边）。本项目把 t 用 `smoothstep` 捏成**渐变曲线**，得到平滑过渡的颜色层次。

**两个核心函数再复习：**

```metal
mix(a, b, t) = a * (1 - t) + b * t
// t = 0 → 返回 a；t = 1 → 返回 b；t 在中间 → 线性混合

smoothstep(edge0, edge1, x)
// x ≤ edge0 → 0；x ≥ edge1 → 1；之间 → 平滑的三次插值
```

**把两者组合**：`smoothstep` 负责把 UV 坐标映射到 `[0,1]` 的过渡量 t，`mix` 负责按 t 把两种颜色混合起来。t 的每个值都对应一种颜色，于是屏幕上出现连续渐变的色带。

---

## 二、片元着色器逻辑

```metal
fragment float4 gradient_fragment_main(GradientVertexOut in [[stage_in]]) {
    float2 uv = in.texCoord;                    // [0,1] 屏幕坐标
    float t   = uv.x;                           // 横轴扫描线 → 渐变方向

    float smoothT = smoothstep(0.0, 1.0, t);    // 平滑化，避免线性雾感

    float3 color1 = float3(1.0, 0.0, 0.0);      // 红
    float3 color2 = float3(0.0, 0.0, 1.0);      // 蓝
    float3 color  = mix(color1, color2, smoothT);// 红 → 蓝渐变

    return float4(color, 1.0);
}
```

**逐行拆解：**

| 片段 | 作用 |
|:---|:---|
| `float2 uv = in.texCoord` | 拿到全屏四边形的 UV 坐标 |
| `float t = uv.x` | 把 x 轴变成 0→1 的插值进度 |
| `smoothstep(0,1,t)` | 让 t 曲线更柔（线性 vs 平滑，肉眼对比上图） |
| `mix(c1, c2, smoothT)` | 按进度在红、蓝间取值 |
| `return float4(color,1)` | 输出像素颜色 |

`uv.x` 跨整个屏幕从 0 走到 1，`mix` 随之连续地从红色过渡到蓝色——没有任何两个像素得到完全相同的颜色。

---

## 三、领域知识：为什么用 `smoothstep` 而不是直接 `mix` 的线性插值

直观上 `mix(c1, c2, uv.x)` 也能得到渐变，那多加一层 `smoothstep` 的意义是什么？

| 版本 | 曲线 | 观感 |
|:---|:---|:---|
| `mix(c1, c2, uv.x)` | 线性 t | 起点终点变化均匀，但过渡中段偏灰、易显"雾感" |
| `smoothstep(0,1,t)` | S 形 t | 两端更慢、中段更快，视觉上过渡"更实更润" |

`smoothstep` 的 S 形曲线，让颜色在首尾有轻微缓入缓出，中间干净利落地完成主变化——这就是专业渐变（CSS 缓动、影视 color grading 同理）与一刀切的朴素线性插值之间的差别。

---

## 四、代码架构

```
runGradient()
└── GradientViewController (MTKViewDelegate)
├── viewDidLoad      Metal → MTKView(黑底) → 队列 → 管线 → 全屏四边形
├── setupPipeline()  gradient_vertex_main + gradient_fragment_main
├── setupVertexData()  6 顶点（pos + uv）
└── draw(in:)        drawPrimitives(.triangle, 6) → present
```

与项目 6 代码高度同构——**仅片元着色器不同**。这也反过来印证阶段一教会你的：同一套全屏四边形脚手架，换一段 fragment 就换了一整套视觉效果。

---

## 五、运行方式

```swift
// main.swift
print("=== Running Color Gradient ===")
runGradient()
```

800×600 窗口内，从左到右红→蓝平滑过渡，中段饱满不灰。

---

## 六、延伸思考

- **简单换成多维混合**：`mix(mix(red, green, uv.x), mix(blue, yellow, uv.x), uv.y)` 就是 **双线性渐变**（四角四色），往后做 UI 背景、HUD 背景都能直接套。
- **渐变不止用于颜色**：把 `mix` 换成对向量（法线、UV 偏移）混合，就是下一阶段"着色器实战"的地基。
- **固定脚手架、变化 fragment**：项目 6/7/8 共用一套 viewController，只有 shader 不同——这是未来写"shader 音效 / 一线特效"时的最佳节奏，也是学习阶段二最好的打开方式。
- 项目 9 是阶段二的大招：**纹理**。全屏四边形不变，这次 fragment 不再"算颜色"，而是从一块真正的 `MTLTexture` 里**采样**颜色——纹理坐标 `uv` 终于名正言顺地工作了。

---

*系列：《Apple Metal 30 小项目》· 第二阶段：着色器特效（6-9）→ 项目 9：纹理贴图*