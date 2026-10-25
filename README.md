# hands-on-apple-metal

Apple Metal 动手学习系列：**79 个可真实跑通的实验**，从渲染第一个三角形
一路写到 Metal 4 张量与融合算子，另有物理可视化教学线（规划 22，已开工 1 个）。
每条线统一结构：原理讲解（README，六段式技术博客）、一键演示脚本（xxx.sh）、
架构图三件套（images/）。

> 🖼️ **交互式架构图**：每个实验的 images/ 目录自带图三件套——图源 JSON（Typed JSON IR）、
> 可交互 HTML（缩放 / 节点聚焦 / 连线追踪 / 深浅主题）与双主题矢量 SVG，
> 全部通过质量门禁校验，由 [Archify](https://github.com/tt-a1i/archify) 工具生成。
> 例外：物理线（physics/）的图三件套是**物理场景**——交互页为手写 canvas 物理操场，
> SVG 由 `build-scene.mjs` 从 scene.json 生成，数值口径与 Swift 实验逐字一致。
> README 正文不再内嵌图，可[在线查看](https://yong-huang.github.io/hands-on-apple-metal/)交互版。

## 五条学习线

| 线 | 目录 | 主线 | 实验 |
|:--|:--|:--|:--|
| **渲染线** | `metal/` | 设备 → 命令队列 → 三角形 → 3D → 光照/阴影/延迟 → Metal 4 | 24 个 |
| **算子线** | `operator/` | 规约 → GEMM → MPS → MLX → 自定义内核 → 融合/量化/引擎 | 30 个 |
| **系统线** | `system/` | Metal × 相机/视频/窗口/CoreML 的跨界整合 | 14 个 |
| **创意线** | `creative/` | 生成艺术 / 游戏物理 / 声音玩具 / AI 生成（规划见 docs/metal_creative.md） | 11 个（规划 24） |
| **物理线** | `physics/` | 普物全领域可视化：力学/波/热/电磁/混沌/相对论/量子（规划见 docs/physics.md） | 1 个（规划 22） |

五条线共享同一套 Metal 底座（`MTLDevice` / `MTLCommandQueue`）：
渲染线管「画」，算子线管「算」，系统线把 Metal 接进真实系统能力，创意线管「玩」，
物理线管「懂」——物理定律亲手算一遍、看得见。

## 环境要求

- Apple Silicon Mac（M1+）+ macOS 13+（Metal 4 实验 23-30 需 macOS 26+）
- Xcode Command Line Tools（`xcode-select --install`）——跑实验只需要 `swiftc`
- 算子线 14-30 需 MLX：`pip3 install mlx`
- 渲染线 GUI 实验会开窗口；脚本化验证用 `AUTO_QUIT=秒数` 自动退出

```bash
scripts/load_resources.sh   # 一键体检：芯片 / swiftc / Metal 设备
```

## 目录结构

```
hands-on-apple-metal/
├── README.md             # 本文档：系列总目录
├── LICENSE               # MIT
├── docs/
│   ├── metal.md          # 路线图：30 项目清单（已标注重复项与完成状态）
│   ├── operator.md       # 路线图：30 项目清单（同上）
│   ├── metal_system.md   # 路线图：系统级 30 项目清单
│   ├── metal_creative.md # 路线图：创意玩具 24 项目清单（游戏/艺术/声音/AI）
│   └── physics.md        # 路线图：物理可视化 22 项目清单（力学/波/热/电磁/混沌/量子）
├── scripts/
│   └── load_resources.sh # 公共脚本：Metal 环境体检
├── metal/NN_xxx/         # 渲染线：README + xxx.sh + Swift 程序 + images 三件套
├── operator/NN_xxx/      # 算子线：结构同上（14+ 为 Python/MLX）
├── system/NN_xxx/        # 系统级线：Metal × 相机/视频/音频/CoreML，见 docs/metal_system.md
├── creative/NN_xxx/      # 创意线：生成艺术/游戏/声音/AI 玩具，见 docs/metal_creative.md
└── physics/NN_xxx/       # 物理线：普物可视化实验（规划中），见 docs/physics.md
```

每个实验目录：README（六段式技术博客）· `xxx.sh`（build→observe→clean）·
程序本体（Swift 单文件 / Python 单文件）· images 三件套。

## 渲染线实验（metal/）

| # | 实验 | 主题 |
|:--|:--|:--|
| 01 | [01 获取 GPU 设备](metal/01_gpu_info/README.md) | MTLDevice 能力契约、统一内存 |
| 02 | [02 第一个命令队列](metal/02_command_queue/README.md) | Queue/Buffer 三层骨架、异步模型 |
| 03 | [03 第一个三角形](metal/03_triangle/README.md) | MTKView、渲染管线、NDC |
| 04 | [04 索引缓冲画矩形](metal/04_rectangle/README.md) | 索引缓冲、TriangleStrip |
| 05 | [05 旋转动画三角形](metal/05_animated_triangle/README.md) | Uniform Buffer、每帧循环 |
| 06 | [06 片元着色器棋盘格](metal/06_chessboard/README.md) | 全屏四边形、fract/step |
| 07 | [07 距离场画圆](metal/07_circle/README.md) | length 距离场、smoothstep 抗锯齿 |
| 08 | [08 颜色渐变](metal/08_gradient/README.md) | mix 权重插值 |
| 09 | [09 纹理贴图](metal/09_texture/README.md) | MTLTexture、Sampler、采样管线 |
| 10 | [10 3D 立方体](metal/10_cube/README.md) | 透视投影、MVP、深度测试 |
| 11 | [11 光照立方体](metal/11_lit_cube/README.md) | 法线、漫反射 + 环境光 |
| 14 | [14 GPU 灰度滤镜](metal/14_grayscale/README.md) | compute 读写纹理、CPU 回读验证 |
| 15 | [15 GPU 粒子系统](metal/15_particles/README.md) | 万级粒子状态更新、point 图元 |
| 16 | [16 Compute→Render](metal/16_compute_to_render/README.md) | 同命令缓冲编排、程序化几何 |
| 21 | [21 光线追踪](metal/21_raytracer/README.md) | MPSRayIntersector、重心坐标着色 |
| 22 | [22 实例化渲染](metal/22_instancing/README.md) | 400 实例 1 次 draw |
| 23 | [23 帧捕获](metal/23_gpu_capture/README.md) | MTLCaptureManager、.gputrace |
| 24 | [24 OBJ 模型](metal/24_obj_model/README.md) | 最小解析器、资产到渲染 |
| 25 | [25 阴影贴图](metal/25_shadow_map/README.md) | 光深 Pass、采样比较、Metal z 坑 |
| 26 | [26 延迟着色](metal/26_deferred/README.md) | G-Buffer、MRT、屏幕空间光照 |
| 27 | [27 MTLTensor](metal/27_mtl_tensor/README.md) | Metal 4 张量、shape 语义 |
| 28 | [28 MTL4 命令栈](metal/28_ml_encoder/README.md) | Allocator/ArgumentTable/ResidencySet |
| 29 | [29 Shader ML 全链路](metal/29_shader_ml/README.md) | tensor 模板编译链卡点定位 |
| 30 | [30 ML+图形混合管线](metal/30_ml_graphics/README.md) | MTL4 队列 + SharedEvent + 渲染 |


## 算子线实验（operator/）

| # | 实验 | 主题 |
|:--|:--|:--|
| 01 | [01 向量加法算子](operator/01_vector_add/README.md) | compute kernel、五步骨架 |
| 02 | [02 线程索引](operator/02_thread_index/README.md) | Grid/Threadgroup/Thread 层级 |
| 03 | [03 向量点积规约](operator/03_reduction/README.md) | threadgroup 内存、树形归并 |
| 04 | [04 GEMM Naive](operator/04_matmul_naive/README.md) | 基线内核 11.7 GFLOPS |
| 05 | [05 GEMM Tiled](operator/05_matmul_tiled/README.md) | 分块复用 90 GFLOPS |
| 06 | [06 Roofline 测量](operator/06_roofline/README.md) | 实测 220 GB/s / 2.26 TFLOPS |
| 07 | [07 Sobel 边缘检测](operator/07_sobel/README.md) | MPS 三步曲 |
| 08 | [08 高斯模糊](operator/08_gaussian_blur/README.md) | sigma 参数化验证 |
| 09 | [09 Bloom 辉光](operator/09_bloom/README.md) | 三滤镜流水线 |
| 10 | [10 阈值二值化](operator/10_threshold/README.md) | 解析解验证 |
| 11 | [11 MPSGraph](operator/11_mpsgraph/README.md) | 声明式计算图 |
| 12 | [12 MPS 矩阵乘法](operator/12_mps_matmul/README.md) | 1270 GFLOPS 商业内核 |
| 13 | [13 逐元素加法](operator/13_mps_elementwise/README.md) | float4 向量化 75 GB/s |
| 14 | [14 MLX 与统一内存](operator/14_mlx_metal/README.md) | 零拷贝、惰性触发 |
| 15 | [15 惰性执行](operator/15_mlx_lazy/README.md) | 20 层记账一次 eval |
| 16 | [16 GELU 融合](operator/16_gelu_compile/README.md) | mx.compile 3× 提速 |
| 17 | [17 RMSNorm](operator/17_rmsnorm/README.md) | 手写对齐 mx.fast |
| 18 | [18 数值稳定 Softmax](operator/18_softmax/README.md) | log-sum-exp、反例触发 |
| 19 | [19 激活函数对比](operator/19_activations/README.md) | ReLU/SiLU/GELU 曲线与性能 |
| 20 | [20 Attention](operator/20_attention/README.md) | 手写 SDPA vs 融合内核 |
| 21 | [21 自定义 nn.Module](operator/21_nn_module/README.md) | 参数注册与 safetensors |
| 22 | [22 自定义 Metal 内核](operator/22_custom_kernel/README.md) | mx.fast.metal_kernel |
| 23 | [23 自定义 GEMV](operator/23_gemv/README.md) | 一行一组 + 组内规约 |
| 24 | [24 融合 RMSNorm+QKV](operator/24_fused_rmsnorm_qkv/README.md) | 手写融合、权重约定 |
| 25 | [25 INT4 量化 GEMV](operator/25_int4_gemv/README.md) | 解量化融合、显存 −75% |
| 26 | [26 KV Cache](operator/26_kv_cache/README.md) | 环形写入、零拷贝读取 |
| 27 | [27 融合 GEMM+GELU](operator/27_fused_gemm_act/README.md) | epilogue 融合 |
| 28 | [28 轻量推理引擎](operator/28_mini_engine/README.md) | 5 算子注册表 + 图编排 |
| 29 | [29 自定义滤镜](operator/29_custom_filter/README.md) | MPS + 自研内核流水线 |
| 30 | [30 基准测试框架](operator/30_benchmark/README.md) | 预热/多轮/双回归 |

## 系统级线实验（system/）

> 清单见 [metal_system.md](docs/metal_system.md)：Metal 与相机/视频/窗口/CoreML 的跨界整合，产出可日常使用的作品。

| # | 实验 | 主题 |
|:--|:--|:--|
| 01 | [脱离 MTKView](system/01_cametal_layer/README.md) | CAMetalLayer 裸驱动、DisplayLink、SwiftUI 集成 |
| 02 | [SwiftUI Shader 特效](system/02_swiftui_shader/README.md) | colorEffect/distortion/layer 三特效、metallib 链路 |
| 03 | [相机实时滤镜](system/03_camera_texture/README.md) | AVFoundation、CVMetalTextureCache 零拷贝、四滤镜 |
| 04 | [三路推理基准](system/04_ane_bench/README.md) | coremltools 建模、GPU/ANE/CPU 对照 |
| 05 | [Vision 人脸马赛克](system/05_vision_face/README.md) | Vision 检测 + Metal 量化后处理 |
| 06 | [超分辨率渲染](system/06_metalfx/README.md) | 低分辨率渲染 + bilinear 放大 |
| 07 | [IOSurface 零拷贝](system/07_iosurface/README.md) | IOSurface 跨框架/跨进程共享 |
| 08 | [Metal 滤镜视频帧处理](system/08_vt_player/README.md) | 视频帧纹理上传 → 内核滤镜 → 回读验证 |
| 09 | [Metal 离屏渲染帧序列](system/09_mp4_export/README.md) | 离屏渲染、像素回读，视频导出的前置环节 |
| 10 | [EDR 渲染](system/10_edr/README.md) | 扩展动态范围、HDR |
| 11 | [多窗口渲染](system/11_multi_window/README.md) | 共享渲染器、多 CAMetalLayer |
| 12 | [帧率 HUD](system/12_display_hud/README.md) | 帧时间曲线叠加 |
| 13 | [Core Image 滤镜链与 Metal 互操作](system/13_ci_metal/README.md) | 现成滤镜 vs 自写内核、共享 GPU 纹理 |
| 14 | [vDSP 对照](system/14_vdsp_metal/README.md) | Accelerate/vDSP 与 Metal 同任务对照 |

## 创意线实验（creative/）

> 清单见 [metal_creative.md](docs/metal_creative.md)：独立玩具集，随做随玩，可跳跃顺序。

| # | 实验 | 主题 |
|:--|:--|:--|
| 01 | [极光渐变板 Plasma](creative/01_plasma/README.md) | 全屏四边形、正弦叠加色场、余弦调色板、离屏导出 |
| 02 | [分形探险家 Mandelbrot/Julia](creative/02_fractal/README.md) | 逃逸时间、平滑着色、交互缩放、10⁴ 倍深放大 |
| 03 | [Domain Warping 壁纸生成器](creative/03_warp/README.md) | 值噪声、fbm、两层域扭曲、4K 离屏导出 |
| 04 | [Metaballs 果冻泡泡](creative/04_metaball/README.md) | 隐式曲面、场叠加融合、高度场光照、拖拽交互 |
| 05 | [图灵花纹 Gray-Scott](creative/05_turing/README.md) | compute 乒乓、反应扩散、9 点拉普拉斯、F-k 相图 |
| 06 | [SDF Raymarching 小场景](creative/06_raymarch/README.md) | 有向距离场、球体追踪、smin 光滑并集、软阴影与 AO |
| 07 | [Mandelbulb 3D 分形雕塑](creative/07_mandelbulb/README.md) | 球坐标迭代、距离估计、orbit trap 调色 |
| 08 | [GPU 生命游戏](creative/08_gol/README.md) | 元胞自动机、compute 双缓冲、B3/S23、可执行验收 |
| 09 | [打砖块 Breakout](creative/09_breakout/README.md) | 游戏状态机、圆 vs AABB、子步进防隧穿、实例化渲染 |
| 10 | [烟花模拟器](creative/10_fireworks/README.md) | 粒子池 swap-remove、重力阻力积分、加法混合 |
| 11 | [可撕裂布料](creative/11_cloth/README.md) | Verlet 积分、距离约束迭代、动态撕边、应变着色 |

## 物理线实验（physics/）

> 清单见 [physics.md](docs/physics.md)：**物理是主角、Metal 是教具**的教学互补线——22 个可交互普物实验，
> 参数真实 SI 单位，验收对照教科书公式定量比对（"看着像"不算过，"对得上教科书"才算过）。

| # | 实验 | 主题 |
|:--|:--|:--|
| 01 | [抛体运动：真空 vs 空气阻力](physics/01_projectile/README.md) | RK4 数值积分、二次空气阻力、最优射角左移、定量验收 11 断言 |

规划中的其余 21 个实验按六个阶段推进：

| 阶段 | 实验主题 |
|:--|:--|
| 第一阶段：力学地基与数值方法 | 抛体 ✅、单摆、开普勒两体、碰撞与守恒律 |
| 第二阶段：振动与波 | 耦合摆简正模、弦振动 FDTD、双缝干涉、多普勒、拍频与 FFT |
| 第三阶段：热学与统计 | 麦克斯韦-玻尔兹曼分布、热传导、布朗运动与扩散 |
| 第四阶段：电磁与光 | 电场线等势面、回旋运动、光线追迹、一维 FDTD 麦克斯韦 |
| 第五阶段：流体与混沌 | 卡门涡街 LBM、双摆混沌、Lorenz 吸引子 |
| 第六阶段：现代物理入门 | 相对论光锥、薛定谔能级、量子隧穿 |

## 学习路线

1. **渲染主干**：metal 01 → 11（2D + 3D 入门）→ 14-16（渲染×计算）→ 21-26（进阶渲染）→ 27-30（Metal 4）
2. **算子主干**：operator 01 → 13（Metal 手写/MPS）→ 14-30（MLX 与融合/量化）
3. **系统主线**：system 01/02（窗口与 SwiftUI）→ 03/08/09（相机与视频）→ 04/05/13/14（CoreML/图像/vDSP）→ 06/07/10/11/12（进阶系统）
4. **创意线**：随做随玩不设路线；shader 艺术阶段与渲染线 06-08 手法互通，适合穿插调剂
5. **物理线**：项目 1-4 先打数值方法地基（RK4 + 守恒监控），之后按普物章节任选；与创意线的物理玩具（烟花/布料/星系）是定量版与玩具版关系，见清单末尾对照表
6. 深入方向见五份路线图；渲染线与算子线的重复项（6 对）二选一，推荐算子线版本。

## 性能速览（Apple M5 Pro 实测）

手写 Tiled GEMM 90 GFLOPS → MPS 1270 GFLOPS ｜ MLX FP32 MatMul 峰值 19.3 TFLOPS ｜
带宽上限 220 GB/s（拐点 ≈10 FLOP/B）｜ INT4 权重显存 −75%

## 遗留说明

- 早期博客（metal/blog）与两处 Xcode 工程均已删除，git 历史可查；
  博客内容已并入各实验 README，各实验目录是唯一权威代码路径。
