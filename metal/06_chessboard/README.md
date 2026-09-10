# 06 · 片元着色器棋盘格：fract/step 的空间重复

> 前几个实验的颜色都来自顶点——想画图案就得堆几何。
> 换个思路：给 GPU 一个全屏四边形当画布，让片元着色器**逐像素用数学公式**决定颜色。
> 本实验用两个内建函数 `fract` + `step`，零几何成本画出一块无限棋盘。

## 1. 为什么需要它

顶点色只能表达"大面渐变"，一切细节图案（棋盘、条纹、圆点）如果都靠几何拼出来，顶点数会爆炸。片元着色器提供了另一种范式：**程序化图案**（procedural pattern）——每个像素根据自身坐标套公式算颜色。这个范式是后续圆形、渐变乃至整个 shader art 的地基，也是全系列"全屏四边形脚手架"的第一个住户。

## 2. 总览：核心机制一图看懂

![棋盘格数据流](images/chessboard.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/06_chessboard/images/chessboard.html)（或本地打开 [`images/chessboard.html`](images/chessboard.html)）。

片元坐标 → 乘格子数 N 后 `fract` 折叠进 0…1（空间重复）→ `(x+y)` 奇偶经 `step` 判定 0/1 → 黑白上色。一句话心智模型：**fract 把无限平面折叠进一个格子，step 在格子内一分为二**。

## 3. 快速开始

```bash
./chessboard.sh               # 一条龙：build → observe → clean
AUTO_QUIT=6 ./chessboard.sh observe   # 6 秒自动退出
```

观察要点：全屏黑白棋盘格，格子规整无锯齿感（远看）；拖拽窗口大小，格子数随视口变化。

验证方法：把着色器里格子密度 N 改大（如 8→16），重编译后格子翻倍变密——证明图案完全由公式生成，与几何无关。

## 4. 核心概念

### 4.1 全屏四边形（Fullscreen Quad）

铺满屏幕的两个三角形（正好用上一篇的 TriangleStrip 技巧），顶点着色器几乎是直通（passthrough）。它的唯一使命是产生足够多的片元，让 fragment shader 有发挥的画布。**之后 07、08 两个实验共用这套脚手架，只换 fragment 函数就换了整个画面**。

### 4.2 `fract`——空间重复的灵魂

`fract(x)` 取小数部分，把任意大的坐标折叠进 [0,1)。片元坐标除以屏幕尺寸再乘格子数 N，经 `fract` 后每个格子内部都得到一套完整的 0…1 局部坐标——这就是"无限重复"的实现原理。

### 4.3 `step`——一分为二的硬边界

`step(edge, x)` 返回 `x >= edge ? 1 : 0`，输出只有两个值、边界锐利。棋盘判定 `(fx + fy)` 后取奇偶：相邻格子奇偶相反，黑白天然交错。它没有过渡带——这正是棋盘需要的"硬朗"，而在 07 画圆时会换成 `smoothstep` 换取抗锯齿。

### 4.4 易错点

- `fract` 的输入如果没先归一化（除以视口尺寸），格子数会跟着分辨率走，窗口一缩放图案就变。
- `(fx + fy)` 是浮点加法，在格子边界处有精度抖动，极端情况下边界像素会闪烁——生产代码常用 `floor` 后的整数奇偶代替。

## 5. 关键 API 与字段

```metal
// 片元着色器核心三行（Metal Shading Language）
float2 uv = in.position.xy / uResolution;        // 归一化到 0…1
float2 grid = fract(uv * 8.0);                   // ×8 折叠：每格重复一份 0…1
float checker = step(1.0, grid.x + grid.y);      // (x+y) 与 1 比较 → 0 或 1
// checker 再经 (x+y) 整体奇偶翻转得到交替黑白
```

为什么用 `in.position.xy` 而不是顶点传的 uv：`position` 是片元的**屏幕像素坐标**，天然逐像素不同——程序化图案的原始素材。

## 6. 文件结构

```
06_chessboard/
├── README.md                     # 本文档
├── chessboard.sh                 # 主演示脚本：build → observe → clean（AUTO_QUIT 自动退出）
├── main.swift                    # 入口包装：调用 runChessboard()
├── chessboard.swift              # 实验程序本体：全屏四边形脚手架 + 棋盘 fragment
└── images/
    ├── chessboard.dataflow.json  # 图源（Typed JSON IR）
    ├── chessboard.html           # 交互版数据流图（浏览器打开）
    └── chessboard.svg            # 双主题矢量版（README 内嵌）
```

## 7. 面试要点

- **全屏四边形的作用？** 提供铺满视口的片元来源，配合直通 vertex shader，把 fragment shader 变成"逐像素程序"，是后处理与程序化图案的标准载体。
- **`fract` 如何实现无限重复？** 取小数把任意坐标折叠进 [0,1)，每个周期得到相同的局部坐标；乘 N 控制重复密度。
- **`step` 与 `smoothstep` 的选择依据？** 要锐利边界（棋盘、色块分割）用 step；要抗锯齿或柔和过渡（圆边、渐变）用 smoothstep。
- **程序化图案相比贴图的优势？** 零内存占用、任意分辨率无失真、参数（密度/相位）即时可调；代价是每像素的 ALU 开销。

## 8. 总结

从"几何给颜色"到"公式给颜色"，这是着色器思维的转折点。`step` 的硬边界画棋盘正合适，但画圆就会满边锯齿——下一篇请出 `length` 与 `smoothstep`，画一个边缘柔和的正圆。

→ 下一篇：[07 · 距离场画圆](../07_circle/README.md)
