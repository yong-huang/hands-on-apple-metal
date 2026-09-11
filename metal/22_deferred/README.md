# 22 · 延迟着色：G-Buffer + 屏幕空间光照

> 前向渲染里，每加一盏灯，每个物体都要重算一遍光照。
> 延迟着色换个顺序：先把几何属性"拍照"存下来，光照推迟到全屏一次做完。
> 这是现代游戏引擎的标准架构，也是 MRT（多渲染目标）的教科书案例。

## 1. 为什么需要它

复杂场景中像素被重复着色（overdraw），光源一多前向渲染成本爆炸。延迟着色把成本拆成"几何遍历（与光源无关）+ 全屏光照（与几何无关）"，光源数量不再拖累几何管线。

## 2. 总览：核心机制一图看懂

![延迟着色数据流](images/deferred.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/22_deferred/images/deferred.html)（或本地打开 [`images/deferred.html`](images/deferred.html)）。

Pass1 把反照率与法线写进两张 G-Buffer 纹理（MRT），Pass2 全屏逐像素读它们算光照。一句话心智模型：**先拍照存证据，再统一审案**。

## 3. 快速开始

```bash
./deferred.sh               # 一条龙
AUTO_QUIT=6 ./deferred.sh observe
```

真实输出：

```
G-Buffer: 1024×768 albedo + normal（MRT 两张）+ depth32Float；场景 78 顶点
G-Buffer 统计: 红立方体 4.35% | 蓝立方体 5.02% | 朝上法线(地面) 53.0%
✅ MRT 验证通过：反照率与法线两张目标都被正确写入
```

窗口显示两个立方体与地面的延迟光照。验证方法：回读两张 G-Buffer 做全图统计——红/蓝立方体占比与朝上法线占比都可解析预期。

## 4. 核心概念

### 4.1 MRT：多渲染目标

片元输出结构体用 `[[color(0)]]`、`[[color(1)]]` 标明写到哪张目标——一次 draw 同时产出反照率图与法线图。管线描述符要为两张目标各声明像素格式。

### 4.2 法线编码

法线范围 [−1,1]，存进 rgba8Unorm 要编码 `*0.5+0.5`，读回 `*2−1`。这是 G-Buffer 的通用技巧（精度敏感场景用 rg32Float 存法线）。

### 4.3 全屏光照 Pass

一个铺满屏幕的四边形，fragment 逐像素读 G-Buffer：`base * (0.3 + 0.7 * dot(N,L))`。加第 N 盏灯只是这个循环多一轮——几何成本纹丝不动。

### 4.4 易错点

- MRT 的 `[[color(n)]]` 标在**片元输出**上，标到顶点输出直接编译错。
- 全屏四边形顶点 z 必须在 Metal 的 [0,1]（本实验用 0.5）。
- G-Buffer 带宽巨大：分辨率 ×2 就是带宽 ×2——移动端要做精简 G-Buffer。

## 5. 关键 API 与字段

```swift
let g = MTLRenderPipelineDescriptor()
g.colorAttachments[0].pixelFormat = .rgba8Unorm   // albedo
g.colorAttachments[1].pixelFormat = .rgba8Unorm   // normal（MRT）
g.depthAttachmentPixelFormat = .depth32Float
```

```metal
struct GOutFrag {
    float4 albedo [[color(0)]];
    float4 normal [[color(1)]];
};
```

## 6. 文件结构

```
26_deferred/
├── README.md                  # 本文档
├── deferred.sh                # 主演示脚本
├── main.swift                 # 入口包装：调 runDeferred()
├── deferred.swift             # 实验程序：G-Buffer Pass + 光照 Pass + 回读验证
└── images/
    ├── deferred.dataflow.json # 图源
    ├── deferred.html          # 交互版
    └── deferred.svg           # 双主题矢量版
```

## 7. 深入要点

- **延迟着色 vs 前向渲染？** 光照从几何遍历中解耦，光源扩展性 O(1)；代价是 G-Buffer 带宽、透明物体难处理、MSAA 困难。
- **G-Buffer 通常存什么？** 反照率、法线、深度（或位置）、材质参数（roughness/metallic）——布局是带宽与质量的权衡。
- **MRT 是什么？** 一次片元着色写入多张颜色附件，由 `[[color(n)]]` 指定目标槽位。
- **透明物体为什么难？** 延迟着色每像素只存一份表面——透明需要前向通道补充（混合无法"延迟"）。

## 8. 总结

渲染篇工业级架构落地：MRT、G-Buffer、屏幕空间光照。至此渲染线的老项目全部实现。接下来进入 Metal 4 时代——从张量开始。

→ 下一篇：[27 · MTLTensor](../23_mtl_tensor/README.md)
