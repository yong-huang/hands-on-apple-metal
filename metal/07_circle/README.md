# 07 · 距离场画圆：length + smoothstep

> `step` 的硬边界画棋盘很帅，但直接拿来画圆，边缘会爬满锯齿。
> 圆的本质是"到圆心距离小于 r"——先把距离算出来，再让边界**柔和地**过渡。
> 本实验引入距离场（SDF）思维与抗锯齿的标配组合 `length` + `smoothstep`。

## 1. 为什么需要它

判断"像素在不在圆内"用 `step(r, d)` 只有两个结果，边界像素非黑即白，锯齿不可避免。距离场思维更进一步：不只问"内/外"，而是算出**每个像素到边界的距离**，在边界两侧各留约 1 像素的过渡带做平滑插值——锯齿消失。SDF（Signed Distance Field）是现代字体渲染、UI 图标、ray marching 的共同地基，正圆是它的最小入门案例。

## 2. 总览：核心机制一图看懂

![距离场画圆数据流](images/circle.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/metal/07_circle/images/circle.html)（或本地打开 [`images/circle.html`](images/circle.html)）。

居中 UV → `length(uv)` 得每像素到圆心的距离 d → d 与半径 r 一起送进 `smoothstep` → 输出 0…1 的透明度。一句话心智模型：**圆不是画出来的，是距离场 `d < r` 的等值线**。

## 3. 快速开始

```bash
./circle.sh               # 一条龙：build → observe → clean
AUTO_QUIT=6 ./circle.sh observe   # 6 秒自动退出
```

观察要点：屏幕中心一个正圆，边缘平滑无锯齿；圆外是背景色。

验证方法：把 `smoothstep` 换成 `step` 重编译——边缘立刻锯齿化。这一个 A/B 对比就是抗锯齿原理最直观的实验。

## 4. 核心概念

### 4.1 UV 平移：原点搬到屏幕中心

片元坐标除以视口得到 [0,1]² 的 UV，再 `uv - 0.5` 把原点移到中心（y 乘宽高比修正形变）。此刻每个像素持有一个"以圆心为原点的向量"。

### 4.2 `length`——距离场的原料

`length(uv)` 求向量模长，即该像素到圆心的欧氏距离 d。d 在整个屏幕上构成一张连续的"高度图"：圆心处为 0，越远越大——等值线 `d = r` 就是我们想要的圆。

### 4.3 `smoothstep`——抗锯齿的灵魂

`smoothstep(a, b, x)` 在 [a,b] 区间内做三次多项式平滑过渡，区外钳位到 0/1。把过渡带设在 `r - 1px` 到 `r + 1px`：边界像素得到中间值，肉眼即是无锯齿的柔和圆边。过渡带宽取"每像素一个单位"是抗锯齿的黄金准则。

### 4.4 易错点

- UV 忘了乘宽高比：圆会变椭圆（x、y 的像素密度不同）。
- 过渡带写死成常数（如 0.01）：窗口缩放后带宽对应的物理像素数变化，锯齿时隐时现；理想值随分辨率自适应。
- `smoothstep` 参数顺序反了（edge > x 方向弄反），圆内外会整体反转。

## 5. 关键 API 与字段

```metal
float2 uv = (in.position.xy / uResolution - 0.5) * float2(uAspect, 1.0);
float d = length(uv);                                  // 距离场：每像素到圆心
float circle = 1.0 - smoothstep(uRadius - aa, uRadius + aa, d);
// aa ≈ 1 像素对应的 UV 宽度；circle ∈ 0…1，边界处平滑过渡
return float4(mix(bgColor, fgColor, circle), 1.0);     // mix 上色
```

为什么 `1.0 - smoothstep(...)`：smoothstep 从 0 涨到 1，而圆内应为 1——翻转方向后，d 越小值越大，圆心实、圆外虚。

## 6. 文件结构

```
07_circle/
├── README.md                     # 本文档
├── circle.sh                     # 主演示脚本：build → observe → clean（AUTO_QUIT 自动退出）
├── main.swift                    # 入口包装：调用 runCircle()
├── circle.swift                  # 实验程序本体：距离场圆 + smoothstep 抗锯齿
└── images/
    ├── circle.dataflow.json      # 图源（Typed JSON IR）
    ├── circle.html               # 交互版数据流图（浏览器打开）
    └── circle.svg                # 双主题矢量版（README 内嵌）
```

## 7. 深入要点

- **什么是距离场（SDF）？** 每点存"到表面最近距离"的函数；形状 = 等值线。支持平滑布尔运算（并/交/差只需 min/max），是程序化建模的基础。
- **`smoothstep` 为什么能抗锯齿？** 把二值判定改为宽度约 1 像素的连续过渡，边界像素得到中间覆盖度，等效于对形状做盒式滤波。
- **`length` + `smoothstep` 画圆比几何圆好在哪？** 零几何、参数（半径/位置）即时可调、天然抗锯齿；还能轻松推广到环、多边形组合。
- **过渡带宽度怎么定？** 与像素大小挂钩（fwidth 或 1/分辨率），保证"每像素约一个过渡"，太窄仍有锯齿、太宽边界发糊。

## 8. 总结

正圆到手，`step`（硬）与 `smoothstep`（软）的分工也亲眼看过了。同样的框架，把"距离判定"换成"位置插值"就是下一篇的主角——用 `mix` 铺一条从红到蓝的渐变。

→ 下一篇：[08 · 颜色渐变](../08_gradient/README.md)
