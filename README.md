# hands-on-metal

Apple Metal 动手学习系列：**54 个可真实跑通的实验**，从渲染第一个三角形
一路写到 Metal 4 张量与融合算子。每条线统一结构：原理讲解（README）、
一键演示脚本（xxx.sh）、架构图三件套（images/）。

> 🖼️ **交互式架构图**：每个实验自带图三件套——图源 JSON（Typed JSON IR）、
> 可交互 HTML（缩放 / 节点聚焦 / 连线追踪 / 深浅主题）与双主题矢量 SVG（README 内嵌），
> 全部通过质量门禁校验，由 [Archify](https://github.com/tt-a1i/archify) 工具生成。
> 开启 GitHub Pages 后可[在线查看](https://yong-huang.github.io/hands-on-metal/)。

## 两条学习线

| 线 | 目录 | 主线 | 实验 |
|:--|:--|:--|:--|
| **渲染线** | `metal/` | 设备 → 命令队列 → 三角形 → 3D → 光照/阴影/延迟 → Metal 4 | 24 个（序号连续） |
| **算子线** | `operator/` | 规约 → GEMM → MPS → MLX → 自定义内核 → 融合/量化/引擎 | 30 个 |

两条线共享同一套 Metal 底座（`MTLDevice` / `MTLCommandQueue`）：
渲染线管「画」，算子线管「算」。先渲染后计算，或交替推进皆可。

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
hands-on-metal/
├── README.md             # 本文档：系列总目录
├── LICENSE               # MIT
├── metal.md              # 路线图：30 项目清单（已标注重复项与完成状态）
├── operator.md           # 路线图：30 项目清单（同上）
├── scripts/
│   └── load_resources.sh # 公共脚本：Metal 环境体检
├── metal/NN_xxx/         # 渲染线：README + xxx.sh + Swift 程序 + images 三件套
├── operator/NN_xxx/      # 算子线：结构同上（14+ 为 Python/MLX）
```

每个实验目录：README（8 编号章节）· `xxx.sh`（build→observe→clean）·
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
| 12 | [12 3D 立方体](metal/12_cube/README.md) | 透视投影、MVP、深度测试 |
| 13 | [13 光照立方体](metal/13_lit_cube/README.md) | 法线、漫反射 + 环境光 |
| 14 | [14 GPU 灰度滤镜](metal/14_grayscale/README.md) | compute 读写纹理、CPU 回读验证 |
| 15 | [15 GPU 粒子系统](metal/15_particles/README.md) | 万级粒子状态更新、point 图元 |
| 16 | [16 Compute→Render](metal/16_compute_to_render/README.md) | 同命令缓冲编排、程序化几何 |
| 17 | [17 光线追踪](metal/17_raytracer/README.md) | MPSRayIntersector、重心坐标着色 |
| 18 | [18 实例化渲染](metal/18_instancing/README.md) | 400 实例 1 次 draw |
| 19 | [19 帧捕获](metal/19_gpu_capture/README.md) | MTLCaptureManager、.gputrace |
| 20 | [20 OBJ 模型](metal/20_obj_model/README.md) | 最小解析器、资产到渲染 |
| 21 | [21 阴影贴图](metal/21_shadow_map/README.md) | 光深 Pass、采样比较、Metal z 坑 |
| 22 | [22 延迟着色](metal/22_deferred/README.md) | G-Buffer、MRT、屏幕空间光照 |
| 23 | [23 MTLTensor](metal/23_mtl_tensor/README.md) | Metal 4 张量、shape 语义 |
| 24 | [24 MTL4 命令栈](metal/24_ml_encoder/README.md) | Allocator/ArgumentTable/ResidencySet |
| 25 | [25 Shader ML 探测](metal/25_shader_ml/README.md) | tensor 模板编译链卡点定位 |
| 26 | [26 ML+图形混合管线](metal/26_ml_graphics/README.md) | MTL4 队列 + SharedEvent + 渲染 |


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

## 学习路线

1. **渲染主干**：metal 01 → 13（2D + 3D 入门）→ 14-16（渲染×计算）→ 17-22（进阶渲染）
2. **算子主干**：operator 01 → 13（Metal 手写/MPS）→ 14-30（MLX 与融合/量化）
3. **Metal 4 前沿**：metal 23 → 28 → 29 → 30（数据面 → 命令栈 → 编译链 → 混合管线）
4. 深入方向见两份路线图；重复项（6 对）二选一，推荐算子线版本。

## 性能速览（Apple M5 Pro 实测）

手写 Tiled GEMM 90 GFLOPS → MPS 1270 GFLOPS ｜ MLX FP32 MatMul 峰值 19.3 TFLOPS ｜
带宽上限 220 GB/s（拐点 ≈10 FLOP/B）｜ INT4 权重显存 −75%

## 遗留说明

- 早期博客（metal/blog）与两处 Xcode 工程均已删除，git 历史可查；
  博客内容已并入各实验 README，各实验目录是唯一权威代码路径。
