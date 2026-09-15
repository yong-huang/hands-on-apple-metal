# 22 · MLX 自定义 Metal 内核

> Python 里直接内嵌一段 MSL 源码，MLX 负责生成函数签名——
> mx.fast.metal_kernel 是"Python 算子开发"的官方通道。
> 入门只需一个向量加法，但有两个语义坑必须当场踩掉。

## 1. 为什么需要它

MLX 内置算子覆盖不到的地方（自定义量化格式、奇异融合、硬件特性），metal_kernel 让你在 Python 循环里无缝调用 MSL——不需要 Xcode 工程、不需要编译配置。

## 2. 总览：核心机制一图看懂

![自定义内核数据流](images/custom_kernel.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/operator/22_custom_kernel/images/custom_kernel.html)（或本地打开 [`images/custom_kernel.html`](images/custom_kernel.html)）。

输入数组进内核体（签名由 MLX 代生成），输出逐元素断言；反例演示线程不足的后果。一句话心智模型：**声明 IO 名字，只写函数体**。

## 3. 快速开始

```bash
./custom_kernel.sh           # 一条龙
```

真实输出：

```
out[:5] = [0.0, 3.0, 6.0, 9.0, 12.0]
✅ 验证通过：自定义内核 out = a + b 与期望一致
线程只派一半时后半区未写（示例 0, 0）——这就是边界检查的意义
✅ 自定义内核入门完成：声明式 IO + MSL 源码 + 显式网格
```

验证方法：out 与 arange×3 逐元素相等；反例（线程只派一半）输出后半区保持初始值——覆盖不足的错误模式亲眼见过。

## 4. 核心概念

### 4.1 片段式源码

MLX 0.32 的 source 只写**函数体**：`uint i = thread_position_in_grid.x; out[i] = a[i] + b[i];`——kernel 签名、buffer 绑定、dtype 模板全部由 MLX 按输入数组自动生成（老式整段 kernel 写法反而编译失败）。

### 4.2 grid = 总线程数（大坑）

`grid=(N,1,1)` 是**线程总数**而非线程组数——`threadgroup_position_in_grid` 范围是 0…N/threadgroup−1。按 CUDA 习惯把 grid 当组数会静默少算一半（23/25 实测踩过）。

### 4.3 边界覆盖是算子的责任

线程不足时输出后半区是**旧数据**（不报错）。要么 grid 覆盖全部、要么内核里边界检查——算子开发的自我修养。

## 5. 关键代码

```python
add_kernel = metal_kernel(name="my_vector_add",
    input_names=["a", "b"], output_names=["out"],
    source="uint i = thread_position_in_grid.x; out[i] = a[i] + b[i];")
(out,) = add_kernel(inputs=[a, b], output_shapes=[(n,)], output_dtypes=[mx.float32],
                    grid=(n, 1, 1), threadgroup=(256, 1, 1))
```

## 6. 文件结构

```
22_custom_kernel/
├── README.md                     # 本文档
├── custom_kernel.sh              # 主演示脚本
├── custom_kernel.py              # 实验程序：向量加法内核 + 反例
└── images/
    ├── custom_kernel.dataflow.json # 图源
    ├── custom_kernel.html          # 交互版
    └── custom_kernel.svg           # 双主题矢量版
```

## 7. 深入要点

- **MLX metal_kernel 与原生 Metal 的关系？** 底层同样是 MSL + Metal，但签名/编译/绑定由 MLX 托管——开发效率换部分控制粒度。
- **grid 语义为什么要变？** MLX 选择"总线程数"抽象以匹配 dispatchThreads；使用者的心智模型要从"组数"切换。
- **如何防御覆盖不足？** 断言 grid×tg ≥ 元素数，或内核尾边界检查——把它做成算子的单元测试。

## 8. 总结

通道打通。下一篇用这条通道写 GEMV——LLM 解码期的主角。

→ 下一篇：[23 · 自定义 GEMV](../23_gemv/README.md)
