# 14 · MLX 数组与统一内存

> MLX 是苹果为 Apple Silicon 造的 NumPy：数组天生住在统一内存里，
> CPU 与 GPU 引用同一块物理内存——没有 host↔device 拷贝这个概念。
> 本实验验证这个红利，并测出它的真实成本曲线。

## 1. 为什么需要它

传统框架的显存-内存拷贝是性能大坑；MLX 从架构上消灭了它。理解"零拷贝 + 惰性"这对基石，后面所有 MLX 实验的设计逻辑就都通了。

## 2. 总览：核心机制一图看懂

![MLX 统一内存数据流](images/mlx_metal.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/operator/14_mlx_metal/images/mlx_metal.html)（或本地打开 [`images/mlx_metal.html`](images/mlx_metal.html)）。

numpy 数据实体化为 mx.array，GPU 归约后逐元素验证。一句话心智模型：**同一块内存，两颗芯片轮流用**。

## 3. 快速开始

```bash
./mlx_metal.sh           # 一条龙（依赖 MLX：pip3 install mlx）
```

真实输出：

```
✅ GPU 计算结果正确：c = a + b = arange × 3
numpy(64MB) → mx.array 首次实体化: 3.1 ms（含首次 GPU 触达）
10 次完整 GPU 归约（64MB/次）: 4.2 ms，无显式拷贝开销
✅ 验证与零拷贝往返均符合统一内存预期
```

验证方法：`c = a+b` 与 arange×3 逐元素相等；64MB 归约 10 次仅数毫秒——若存在拷贝早已爆表。

## 4. 核心概念

### 4.1 零拷贝的两层含义

`mx.array(numpy数组)` 不复制数据（共享缓冲）；首次 GPU 访问时框架按需实体化。对比 CUDA 的 cudaMemcpy 心智负担骤降。

### 4.2 惰性执行

`c = a + b` 只是记账，`mx.eval(c)` 才触发 GPU——MLX 看到完整表达式后统一调度（15 的主题）。

### 4.3 设备语义

默认跑 GPU；`mx.cpu` 可指定。统一内存下"搬运"不存在，但执行设备仍影响调度与算力。

### 4.4 易错点

- 忘 eval 就 `.tolist()`/打印：MLX 会自动 eval，但性能敏感路径要显式控制时机。
- numpy→mx 的大数组首次实体化有一次性成本（实测 64MB ~3ms）。

## 5. 关键代码

```python
c = a + b            # 记账
mx.eval(c)           # GPU 执行
m = mx.array(n)      # numpy 零拷贝视图
s = mx.sum(m); mx.eval(s)   # 归约
```

## 6. 文件结构

```
14_mlx_metal/
├── README.md                 # 本文档
├── mlx_metal.sh              # 主演示脚本（内置 MLX 依赖检查）
├── mlx_metal.py              # 实验程序：零拷贝 + 归约计时
└── images/
    ├── mlx_metal.dataflow.json # 图源
    ├── mlx_metal.html          # 交互版
    └── mlx_metal.svg           # 双主题矢量版
```

## 7. 面试要点

- **统一内存消除了什么成本？** host↔device 显式拷贝与双份数据的显存占用；代价是需要缓存一致性协议。
- **mx.array 与 numpy 数组的关系？** 可互转且共享缓冲（零拷贝）；类型/布局兼容时转换是视图操作。
- **惰性执行对调试的影响？** 打印/取值会隐式 eval——性能路径与调试路径的评估时机要分开管理。

## 8. 总结

零拷贝确认。下一篇看 MLX 的另一半基石：惰性执行到底省在哪。

→ 下一篇：[15 · 惰性执行](../15_mlx_lazy/README.md)
