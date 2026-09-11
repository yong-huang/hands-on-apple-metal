# 27 · 融合 GEMM + GELU：epilogue 融合

> LLM 推理 80% 的算子是"GEMM 后接激活"。分离执行要把 8MB 结果
> 写回显存再读出来激活；epilogue 融合让激活直接吃寄存器里的累加值。
> 这是手写 GEMM 融合的最小完整案例。

## 1. 为什么需要它

04/05 学了 GEMM，16 学了融合——本实验把两者接上：激活作为 GEMM 的"尾声"（epilogue）在累加器里就地完成。省一次全量往返（1024² fp32 = 8MB 写 + 8MB 读）。

## 2. 总览：核心机制一图看懂

![融合 GEMM+GELU 数据流](images/fused_gemm_act.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/27_fused_gemm_act/images/fused_gemm_act.html)（或本地打开 [`images/fused_gemm_act.html`](images/fused_gemm_act.html)）。

同一个内核用 `fused` 标志切换"裸 GEMM"与"GEMM+GELU"两种输出。一句话心智模型：**累加结果还没落地，激活就地完成**。

## 3. 快速开始

```bash
./fused_gemm_act.sh           # 一条龙
```

真实输出：

```
融合（GEMM+GELU 一趟）: 3.6 ms
分离（GEMM 裸奔，另需 +1 次全量往返做激活）: 3.6 ms + 往返开销
省掉的往返: 1048576 × 4 字节 = 8 MB 的写+读
✅ 融合结果与 CPU 参照一致（64 点抽样）
```

验证方法：C 与"CPU GEMM + GELU"的 64 点抽样一致——注意验证要在融合运行之后读缓冲（本实验实测踩过"验证读了分离结果"的顺序坑）。

## 4. 核心概念

### 4.1 epilogue 的含义

GEMM 累加完成后、写回 C 之前的插入点。GELU 三行代码在寄存器里完成——无中间物化、无额外内核启动。

### 4.2 单内核双模式

`constant bool& fused` 切换输出是否激活：同一个内核当融合版用，也当分离版的 GEMM 段用——对照组免写第二份内核。

### 4.3 本内核仍是朴素 GEMM

融合省的是激活往返（8MB×2），但 GEMM 本体还是 naive（~12 GFLOPS 量级）——融合优化与 GEMM 本体优化（05/12）是正交的两件事，生产中叠加使用。

### 4.4 验证顺序坑（实测）

缓冲里永远躺在"最后一次运行"的结果。先计时分离再验证 → 读到未融合数据 → 假失败。顺序：跑融合 → 验证 → 计时对照。

## 5. 关键代码

```metal
if (fused) {
    acc = 0.5 * acc * (1.0 + tanh(0.7978845608 * (acc + 0.044715 * acc * acc * acc)));
}
C[row * dims.y + col] = acc;    // 激活后一次性写回
```

## 6. 文件结构

```
27_fused_gemm_act/
├── README.md                         # 本文档
├── fused_gemm_act.sh                 # 主演示脚本
├── main.swift                        # 入口包装
├── fused_gemm_act.swift              # 实验程序：双模式内核 + 计时验证
└── images/
    ├── fused_gemm_act.dataflow.json  # 图源
    ├── fused_gemm_act.html           # 交互版
    └── fused_gemm_act.svg            # 双主题矢量版
```

## 7. 深入要点

- **epilogue 还能放什么？** bias 加法、残差相加、缩放、量化——任何"逐输出元素"的后处理都零成本融合。
- **为什么激活放 epilogue 而不是独立内核？** 省一次全量读写 + 一次启动；数据在寄存器里最便宜。
- **融合与 GEMM 优化冲突吗？** 不冲突：先 optimize GEMM 本体，epilogue 原样保留。

## 8. 总结

epilogue 融合到手。综合篇第二站：把算子们组织成一个"引擎"。

→ 下一篇：[28 · 轻量推理引擎](../28_mini_engine/README.md)
