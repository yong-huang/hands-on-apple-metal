# hands-on-metal

Apple Metal 动手学习系列：通过 **11 个可真实跑通的小实验**，从渲染第一个三角形到写出 GPU 向量加法算子。每条线统一结构：原理讲解（README）、一键演示脚本（xxx.sh）、架构图三件套（images/）。

> 🖼️ **交互式架构图**：每个实验都配有由 [Archify](https://github.com/tt-a1i/archify) 生成、通过 showcase 级校验的图，共 11 张三件套：图源 JSON（Typed JSON IR）+ 可交互 HTML（缩放 / 节点聚焦 / 连线追踪 / 深浅主题）+ 双主题矢量 SVG（README 内嵌）。开启 GitHub Pages 后可[在线查看](https://yong-huang.github.io/hands-on-metal/)；克隆到本地用浏览器打开对应实验的 `images/*.html` 也可以。

## 两条学习线

| 线 | 目录 | 主线 | 已完成实验 |
|:--|:--|:--|:--|
| **渲染线** | `metal/` | 设备 → 命令队列 → 三角形 → 索引 → 动画 → 片元三部曲 → 纹理，打通图形管线主干 | 9 个（01-09） |
| **算子线** | `operator/` | 命令骨架 → 线程模型，为规约 / GEMM / MLX 自定义内核打地基 | 2 个（01-02） |

两条线共享同一套 Metal 底座（`MTLDevice` / `MTLCommandQueue`），渲染线管"画"，算子线管"算"——先渲染后计算，或两条线交替推进都可以。

## 环境要求

- Apple Silicon Mac（M1 及以上）+ macOS 13+
- Xcode Command Line Tools（`xcode-select --install`）——**跑实验只需要 `swiftc`，不需要打开 Xcode 工程**；着色器在程序内嵌，由 Metal 运行时编译
- 渲染线实验（03-09）会打开 GUI 窗口；算子线实验纯命令行输出

```bash
scripts/load_resources.sh   # 一键体检：芯片 / swiftc / Metal 设备是否就绪
```

## 目录结构

```
hands-on-metal/
├── README.md             # 本文档：系列总目录
├── LICENSE               # MIT
├── metal.md              # 路线图：渲染+计算 30 项目清单（已标注与算子线的重复项）
├── operator.md           # 路线图：算子开发 30 项目清单（已标注与渲染线的重复项）
├── scripts/
│   └── load_resources.sh # 公共脚本：Metal 环境体检
├── metal/                # 渲染线
│   └── NN_xxx/           # 每个实验统一结构：
│       ├── README.md     #   教程文档（原理 + 实操，内嵌双主题矢量架构图）
│       ├── xxx.sh        #   主演示脚本：build → observe → clean
│       ├── xxx.swift     #   实验程序本体（着色器内嵌，运行时编译）
│       ├── main.swift    #   入口包装（GUI 实验支持 AUTO_QUIT 自动退出）
│       └── images/       #   架构图三件套：xxx.<type>.json / xxx.html / xxx.svg
├── operator/             # 算子线（结构同上）
├── blog/ 与旧 Xcode 工程  # 遗留内容：见下方「遗留说明」
```

## 渲染线实验列表（metal/）

| # | 实验 | 主题 |
|:--|:--|:--|
| 01 | [获取 GPU 设备](metal/01_gpu_info/README.md) | `MTLDevice` 能力契约、统一内存 |
| 02 | [第一个命令队列](metal/02_command_queue/README.md) | Queue/Buffer 三层骨架、异步模型 |
| 03 | [第一个三角形](metal/03_triangle/README.md) | MTKView、渲染管线、NDC |
| 04 | [索引缓冲画矩形](metal/04_rectangle/README.md) | 索引缓冲、TriangleStrip |
| 05 | [旋转动画三角形](metal/05_animated_triangle/README.md) | Uniform Buffer、每帧循环 |
| 06 | [片元着色器棋盘格](metal/06_chessboard/README.md) | 全屏四边形、fract/step |
| 07 | [距离场画圆](metal/07_circle/README.md) | length 距离场、smoothstep 抗锯齿 |
| 08 | [颜色渐变](metal/08_gradient/README.md) | mix 权重插值 |
| 09 | [纹理贴图](metal/09_texture/README.md) | MTLTexture、Sampler、采样管线 |

## 算子线实验列表（operator/）

| # | 实验 | 主题 |
|:--|:--|:--|
| 01 | [向量加法算子](operator/01_vector_add/README.md) | compute kernel、五步骨架、统一内存 |
| 02 | [线程索引与网格配置](operator/02_thread_index/README.md) | Grid/Threadgroup/Thread 层级、内建变量 |

## 学习路线

1. **渲染主干（1 周）**：metal 01 → 09 按序推进，前一个实验都是后一个的地基；每篇 README 的「面试要点」可在复习时自测。
2. **算子入门（2-3 天）**：operator 01 → 02，把渲染线学的命令队列直接复用到计算场景。
3. **继续深入**：两份路线图（`metal.md` / `operator.md`）各规划了 30 个项目；⚠️ 其中 6 对项目互为重复（见两份路线图内的标注），**二选一即可**，推荐走算子线版本（更深入、含性能对比）。

## 遗留说明

- `metal/blog/` 是本系列早期按项目写的博客，内容已全部并入各实验 README，仅作历史存档保留；
- `metal/LearnMetal/`、`operator/LearnMetalOperator/` 是早期 Xcode 工程，已被各实验目录内"swiftc 独立编译"的方式取代（**实验目录是唯一权威代码**）。确认新结构可用后，这三处可以删除。
