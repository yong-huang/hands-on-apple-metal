# 22 · 实例化渲染：一次 draw 画 400 个

> 400 个物体 = 400 次 draw call？CPU 提交命令的开销会让 GPU 吃不饱。
> 实例化把"同一几何的 N 份拷贝"压成一次绘制：几何存一份，差异存一份。
> 这是植被、人群、粒子 mesh 的标准姿势。

## 1. 为什么需要它

draw call 本身有 CPU 侧成本（状态验证、驱动开销），万级物体时 CPU 先于 GPU 崩溃。实例化把 N 倍开销降为 1 倍 + N 份轻量参数——理解它就理解了"Draw Call 预算"这个词。

## 2. 总览：核心机制一图看懂

![实例化数据流](images/instancing.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-apple-metal/metal/22_instancing/images/instancing.html)（或本地打开 [`images/instancing.html`](images/instancing.html)）。

单三角形几何与 400 份实例数据汇入顶点着色器，一次 draw 输出整个阵列。一句话心智模型：**[[instance_id]] 是"我是第几份拷贝"的自查**。

## 3. 快速开始

```bash
./instancing.sh               # 一条龙
AUTO_QUIT=6 ./instancing.sh observe
```

控制台输出（真实）：

```
几何: 1 个三角形 × 400 个实例 → 每帧只有 1 次 draw call
```

窗口显示 20×20 的三角形阵列，颜色按网格位置渐变。验证方法：`drawPrimitives` 的 `instanceCount` 改成 100，画面只剩 100 个——阵列规模确实由这一个参数驱动。

## 4. 核心概念

### 4.1 实例缓冲

每实例一份 `{offset: float2, color: float4, scale: float}`——位置、颜色、大小三个自由度。它与顶点缓冲一样是普通 MTLBuffer，只是语义上是"每实例一行"。

### 4.2 `[[instance_id]]`

vertex shader 多收一个 `uint iid [[instance_id]]`：0…instanceCount−1。用它索引实例缓冲，物体间差异全部来自数据而非代码分支。

### 4.3 绘制调用变了

`drawPrimitives(type:vertexStart:vertexCount:instanceCount:)` 多了 `instanceCount` 参数——顶点着色器被调用 vertexCount × instanceCount 次。

### 4.4 易错点

- 实例缓冲 stride 与 Swift 结构体不一致 → 数据错位、物体乱飞。
- 忘传 instanceCount（默认 1）→ 只画出一个物体。
- 大量实例时实例缓冲本身成为带宽热点 → 压缩每实例数据（half 精度）。

## 5. 关键 API 与字段

```swift
enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)     // 几何
enc.setVertexBuffer(instanceBuffer, offset: 0, index: 1)   // 实例
enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 400)
```

```metal
Vertex v = verts[vid];
InstanceData d = instances[iid];     // 本实例的差异
float2 p = v.position * d.scale + d.offset;
```

## 6. 文件结构

```
22_instancing/
├── README.md                     # 本文档
├── instancing.sh                 # 主演示脚本
├── main.swift                    # 入口包装：调 runInstancing()
├── instancing.swift              # 实验程序：几何 + 实例缓冲 + 单次 draw
└── images/
    ├── instancing.dataflow.json  # 图源
    ├── instancing.html           # 交互版
    └── instancing.svg            # 双主题矢量版
```

## 7. 深入要点

- **实例化解决什么瓶颈？** CPU 端 draw call 提交开销；同一几何多副本场景下降数量级。
- **[[instance_id]] 与 [[vertex_id]] 的正交性？** 顶点着色器被调用 vid×iid 次，两者组合定位"哪个物体的哪个顶点"。
- **实例化 vs 合批（batching）？** 合批把几何拼进大缓冲（一次 draw 但几何固化）；实例化保留逐实例动态参数。植被用实例化，静态地形用合批。
- **实例数据怎么优化？** half 精度、紧打包、甚至实例侧 GPU 生成（indirect + compute）。

## 8. 总结

一次 draw 的威力到手。下一篇转向 GPU 调试：不看画面，直接把 GPU 的执行明细"录"下来。

→ 下一篇：[23 · 帧捕获](../23_gpu_capture/README.md)
