# 30 · 算子基准测试框架

> 会写算子只是开始，会**测**算子才算专业。预热吸收编译成本、
> 多轮取 min/median 抵消抖动、性能与精度双回归——
> 本实验把这个系列用过的所有计时纪律固化成一个可复用框架。

## 1. 为什么需要它

错误的基准比没有基准更糟（冷启动数字误导优化方向）。本框架三原则：预热、多轮统计、精度回归——MatMul 128→2048 全尺寸段跑一份可信报告。

## 2. 总览：核心机制一图看懂

![基准框架数据流](images/benchmark.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/30_benchmark/images/benchmark.html)（或本地打开 [`images/benchmark.html`](images/benchmark.html)）。

五个规模的 MatMul 经框架计时，产出延迟/TFLOPS/带宽表 + 精度回归。一句话心智模型：**性能报告必须附带精度签证**。

## 3. 快速开始

```bash
./benchmark.sh           # 一条龙
```

真实输出：

```
   规模    延迟(中位)   延迟(最优)      算力       带宽
   512³     0.35ms       0.34ms       7.8T       34G
  1024³     1.12ms       1.10ms      19.2T       69G
  2048³     8.72ms       8.66ms      19.3T      139G
峰值算力: 19.3 TFLOPS @ 2048³（FP32）
精度回归: 512³ 相对误差 7.69e-04（< 1e-3 通过）
✅ 基准框架验证通过：性能 + 精度双回归
```

验证方法：512³ MatMul 与 numpy 对照的相对误差 < 1e-3——被测代码的正确性也是基准的一部分。

## 4. 核心概念

### 4.1 预热的必要性

首轮触发内核选择/编译/缓存加载——冷启动数字可能差 10 倍。预热 3 轮后再开始计时。

### 4.2 min 与 median 的分工

min 代表"硬件能力上限"（无干扰），median 代表"典型体验"。报告两者，防单点好运。

### 4.3 三个指标的换算

TFLOPS = 2n³ / 时间；带宽 = 3n²×4 / 时间。看带宽随规模的增长可判断算子何时进入 compute-bound。

### 4.4 读报告的方法

小规模延迟高 → 启动开销主导（去 batching）；大规模算力趋平 → compute-bound（对照 06 的 2.26T 上限，19.3T 是 FP16 的天下——本报告 FP32）；带宽远低于 220 GB/s → 查布局与分块。

## 5. 关键代码

```python
def bench(fn, iters=20, warmup=3):
    for _ in range(warmup): mx.eval(fn())          # 预热
    times = []
    for _ in range(iters):
        t0 = time.perf_counter(); r = fn(); mx.eval(r)
        times.append((time.perf_counter() - t0) * 1000)
    return min(times), sorted(times)[len(times)//2]
```

## 6. 文件结构

```
30_benchmark/
├── README.md                # 本文档
├── benchmark.sh             # 主演示脚本
├── benchmark.py             # 实验程序：框架 + 全尺寸扫描 + 回归
└── images/
    ├── benchmark.dataflow.json # 图源
    ├── benchmark.html          # 交互版
    └── benchmark.svg           # 双主题矢量版
```

## 7. 深入要点

- **基准测试的三大纪律？** 预热、多轮统计（min+median）、性能与精度同报。
- **为什么报 min 又报 median？** min 是能力上限（抗干扰），median 是典型体验——只报其一都会误导优化决策。
- **跨规模曲线怎么读？** 拐点前启动开销主导（batching 可救）；趋平后看算力对标 Roofline 上限。

## 8. 总结

算子线（operator/）30 个项目全部实现完毕。至此两份路线图上的所有非重复项目——**54 个实验**——都已真实跑通。回到总目录，看看整个系列的版图。

→ 返回总目录：[hands-on-metal](../../README.md)
