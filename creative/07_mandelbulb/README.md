# 07 · Mandelbulb 3D 分形雕塑：距离估计的极限测试

> 把 Mandelbrot 的逃逸时间（判断迭代值是否飞向无穷的判定法）升维到三维空间，用距离估计（不大于真实距离的保守值）代替精确距离做光线步进——
> 一颗 power=8 的分形雕塑实时旋转在窗口里，单帧 11ms。
> 读完本篇你能掌握距离估计（DE）的原理与陷阱，这是 SDF 渲染的进阶必修课。

## Background

Mandelbrot 集合（lab 02：复平面上由"迭代不飞向无穷"的点组成的最著名分形）生活在二维复平面上；想把它升到三维，第一个障碍是数学：复数乘法天然对应平面旋转加缩放，但三维没有这种现成的代数结构。

2009 年 Daniel White 与 Paul Nylander 在 fractalforums 论坛找到答案——把迭代搬进球坐标（用半径、极角、方位角描述一点位置的坐标系），对极角与方位角同乘幂次 n：z → rⁿ(sin nθcos nφ, sin nθ sin nφ, cos nθ) + c。

当 n=8，迭代的有界集合第一次呈现出那颗著名的"分形球"。

第二个障碍是渲染：分形表面无限复杂，不可能建网格。恰逢 lab 06 的 SDF raymarching（有向距离场光线步进，本清单项目 6）成熟，但分形没有精确距离函数——好在可以推导一个"距离估计"（DE，Distance Estimator）：迭代过程中顺带记录半径的放大率，对数换算出一个不大于真实距离的保守值。

DE 每步需要一次 8 轮迭代，是 lab 06 场景函数的几十倍算力，本实验用它实测 Apple Silicon GPU 的算术吞吐。

## What

Mandelbulb 是三维分形：对空间每点做 z → zⁿ+c 的球坐标迭代（本实验 n=8），永不逃逸的点组成集合并成一个带 8 条瓣状脊的分形球。渲染它用的是距离估计——一个"至少离表面这么远"的保守距离，替代 lab 06 里的精确 SDF 喂给球体追踪。

![Mandelbulb 数据流](images/mandelbulb.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/creative/07_mandelbulb/images/mandelbulb.html)（或本地打开 [`images/mandelbulb.html`](images/mandelbulb.html)）。

可以把距离估计想象成"看影子量楼高"：真距离量不到，但每次迭代都把你的视线放大 r 倍，放大率的累积对数恰好约束住"到边界还差多远"的下界。但和直接测量不同的是，这个估计在有限迭代数（8 轮）下会**高估**——步子偶尔迈大，需要乘 0.9 的保险系数并把单步封顶。

## When to Use

- **分形艺术渲染**：Mandelbulb、4D Quaternion Julia 集、Kleinian 群——distance estimation 是这类渲染的通用引擎
- **自然造型的程序化生成**：分形表面与珊瑚、花椰菜、地衣的形态同源，可做程序化资产
- **GPU 算术吞吐压测**：每像素每步一次 8 轮三角函数迭代，是最重的纯算术负载之一

何时不用：需要精确可控的造型或拓扑（建模资产）时，分形是"发现"不是"设计"；交互速率要求极高的场景也应降低迭代数再上。

| 方案 | 差异 | 什么时候选它 |
|:---|:---|:---|
| Mandelbulb 3D 等专用软件 | 参数全、离线渲染质量高；CPU 慢、闭源 | 精出图，不要求实时 |
| Shadertoy 移植 | 公式现成；耦合在 GLSL 里需翻译 | 参考实现学习 |
| CPU 逐像素渲染 | 代码直白；单帧秒级到分钟级 | 离线研究参数 |
| **Metal DE raymarching** | 每帧全屏重算、实时交互 | 本实验：实时 + 全定制 |

## Quick Start

前置条件：装好 Xcode Command Line Tools（`xcode-select --install`）；Metal（Apple 的 GPU 编程框架，Swift 可直接调用）为系统自带。

```bash
./mandelbulb.sh                 # 一条龙：build → observe → clean
./mandelbulb.sh observe         # 拖拽旋转 · 滚轮缩放 · ↑↓ 调 power(2~12)
AUTO_QUIT=7 ./mandelbulb.sh     # 7 秒自动退出（脚本化验证）
./mandelbulb.sh export out.png 8   # 离屏导出 1920×1080 并打印单帧耗时
```

真实输出（全新目录执行 `AUTO_QUIT=7 ./mandelbulb.sh observe`）：

```
=====> [build] swiftc -O main.swift mandelbulb.swift（几秒钟）
编译完成 → .build/mandelbulb

=====> [observe] 运行实验（拖拽旋转 · 滚轮缩放 · ↑↓调power；AUTO_QUIT=秒数 可自动退出）
Device: Apple M5 Pro
造型：Mandelbulb power=8（↑↓ 调 power 2~12，滚轮缩放，拖拽旋转）
[Pipeline ready] vertex_main + fragment_main · 距离估计球体追踪 · 帧率见标题栏
FPS ≈ 57.6（标题栏同步显示）
FPS ≈ 60.0（标题栏同步显示）
FPS ≈ 60.0（标题栏同步显示）

实验结束。
```

真实输出（`./mandelbulb.sh export images/mandelbulb_p8.png 8`，成品见 [images/mandelbulb_p8.png](images/mandelbulb_p8.png)）：

```
=====> [export] 离屏渲染 1920×1080 一帧 → images/mandelbulb_p8.png（power 8，含单帧耗时）
造型：Mandelbulb power=8  尺寸 1920×1080  单帧渲染 10.6 ms
导出 → images/mandelbulb_p8.png
✅ PNG 已写出（1346666 字节）
```

- 观察要点：8 条瓣状脊围绕极轴排列，表面布满罗马花椰菜式的自相似螺旋；↑ 把 power 调到 12 看表面更尖锐、↓ 调到 2 则退化成一个光滑球；滚轮拉近可以看到任意深度的细节
- 验证方法：窗口 FPS 稳定 60（单帧 16.7ms < 33ms 验收线）；`export` 打印的单帧耗时在 1920×1080 下约 10ms；同参数导出重跑逐字节相同
- 诚实预期：远处细节受 110 步行进预算限制会被"雾化"省略；power 越大表面越尖锐但 DE 高估越明显（已用步长封顶抑制）；导出用固定相机角度

## How It Works

**球坐标迭代：二维逃逸时间的三维推广。** 二维 Mandelbrot 的 z² 复数乘法等于"辐角加倍、模长平方"；三维没有复数，就显式操作球坐标——模长 r 取 n 次幂、极角 θ 与方位角 φ 各乘 n：

```metal
float r = length(z);
dr = pow(r, power - 1.0) * power * dr + 1.0;   // 半径放大率的链式累积
float theta = acos(clamp(z.z / max(r, 1e-6), -1.0, 1.0));
float phi = atan2(z.y, z.x);
float zr = pow(r, power);
z = zr * float3(sin(theta*power) * cos(phi*power),
                sin(theta*power) * sin(phi*power),
                cos(theta*power)) + pos;
```

8 轮内 |z| 始终不超过逃逸半径 16 的点属于集合——power=8 时它们组成那颗带 8 条瓣状脊的雕塑。

**距离估计：不求精确，只要下界。** 迭代每轮把 z 的半径放大约 `power·r^(power-1)` 倍，把这个放大率连乘（dr 的链式累积）再取对数，就得到"从这里到分形边界至少还有多远"的估计：

```metal
float m = dot(z, z);
return 0.5 * log(max(m, 1e-6)) * sqrt(m) / dr;
```

它是下界而非精确值——尤其迭代数少时会高估。两个必须的防御：步长乘 0.9，且单步封顶 0.4（远点处 DE 的高估能一步跨过整个分形，本实验开发时真实踩到，见 Pitfalls）。

**命中后的三件套。** 法线用 DE 的数值梯度（6 次采样）；AO 沿法线采 4 个高度；表面颜色由 orbit trap（迭代途中 |z| 曾达到的最小值）驱动——靠近"核心轨道"的区域偏金、远离偏陶土红，配合方向光与边缘光。

距离估计的球体追踪与 lab 06 的精确 SDF 版本框架完全一致，替换的只有距离函数本身。

## Pitfalls & Q&A

- **渲染出的是带环纹的球而不是分形**：现象是画面里一颗光滑的大球，上面有等距圆环。原因：距离公式的半径用错——必须用**逃逸后**的 |z| 计算 `0.5·log(|z|²)·|z|/dr`；误用循环顶部的旧半径（该值只有 1 左右）会让 log 项≈0，DE 处处趋零，光线一起步就满足命中阈值。解法：循环结束后重算 `m = dot(z,z)` 再返回。
- **相机拉远后分形消失（全是天空）**：现象是距离 3.2 一切正常，拉到 5.0 只剩背景。原因：远点处 DE 高估约 1.8 倍（首步 dr 在大 r 下爆炸），一步从 5.0 直接跨到分形背后。解法：单步封顶 `t += min(d*0.9, 0.4)`，远处多走几步、绝不跨过表面。
- **power 调大后帧率下跌**：现象是 power=12 比 2 明显卡。原因：高 power 下表面细节频率高，DE 需要更小步长与更多行进步数才收敛。解法：先保 30 FPS 再提画质——降低行进步数上限或把可交互分辨率减半都是可选项。
- **极点附近出现放射状噪点**：现象是两极处法线闪烁。原因：球坐标在极点退化（θ→0 或 π 时 φ 无定义），acos 与 atan2 对接近零的分母敏感。解法：分母用 `max(r, 1e-6)` 保护（本实验已内置），阈值再小会复发。

**Q：为什么 n=8 是"经典"？**
8 重对称下瓣状脊、螺旋与"菠萝眼"同时出现、结构最丰富；n=2 近似球体、n 越大越尖锐破碎。↑↓ 键现场对比 2/8/12 是理解幂次作用最直观的方式。

**Q：距离估计的数学来源是什么？**
对迭代 z → f(z) + c 做伴随变量微分：|z| 的增长率逐轮相乘（dr 的连乘项），而分形边界正是"发散与不发散"的分界——log(逃逸半径) 除以总放大率给出到达边界的量级估计。它是下界估计，推导假设了局部自相似，这就是它偶尔高估的根源。

**Q：和 lab 02、lab 06 的关系？**
lab 02 的二维逃逸时间回答"这个点逃不逃"，本实验回答"这个点的边界有多远"——同一迭代加了导数记账；lab 06 提供渲染框架，本实验只替换了距离函数。三篇连读，就是从"画分形"到"走进分形"的完整路径。
