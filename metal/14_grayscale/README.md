# 14 · GPU 灰度滤镜：纹理作为计算输出

> 渲染线与计算线在此交汇：这次不是"画"，而是"算"——
> 用 Compute Kernel 逐像素处理一张纹理，再把结果当普通纹理渲染出来。
> 关键新知识：MTLTexture 不只是图片，它是 GPU 上最通用的数据容器。

## 1. 为什么需要它

图像处理（滤镜/后处理/CV 预处理）是 GPU 计算最大的日常场景。它的最小闭环：CPU 备图 → compute 读 A 写 B → 验证 → 渲染消费。理解这个闭环，后面所有"纹理进纹理出"的算子（模糊、融合、AI 输出）都是它的变体。

## 2. 总览：核心机制一图看懂

![灰度滤镜数据流](images/grayscale.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/14_grayscale/images/grayscale.html)（或本地打开 [`images/grayscale.html`](images/grayscale.html)）。

CPU 生成的测试图经 `replace()` 上传，compute 逐像素读 src 写 dst，dst 一边供渲染采样、一边供 CPU 回读验证。一句话心智模型：**纹理 = 带坐标的二维数组，kernel = 逐像素函数**。

## 3. 快速开始

```bash
./grayscale.sh               # 一条龙：build → observe → clean
```

真实输出：

```
测试图 512×512 rgba8Unorm 已生成；compute 管线就绪
  采样0 (10,10) → R=145 G=145 B=145 ✅
  采样1 (256,256) → R=99 G=99 B=99 ✅
  ...
✅ 灰度转换验证通过：所有采样点 R=G=B
```

窗口显示灰度化的测试图。验证方法：5 个采样点的 R、G、B 相等——这正是灰度的定义，回读即证明。

## 4. 核心概念

### 4.1 compute 的纹理访问

kernel 里纹理用 `access::read`（`src.read(gid)`）与 `access::write`（`dst.write(color, gid)`），不经过采样器——逐像素精确访问，适合"输入输出一一对应"的滤镜。需要插值/缩放时才用采样器。

### 4.2 亮度加权

`0.299R + 0.587G + 0.114B` 来自人眼视敏度——绿色权重过半。直接取平均会让绿色通道的细节丢失。

### 4.3 线程网格规划

512×512 像素、32×32 的线程组 → 16×16 组。边界检查 `if (gid >= size) return` 在非整除时必须存在（本例整除，但内核保留防御）。

### 4.4 验证：`.storageModeShared` 的红利

dst 纹理声明 shared 存储，CPU `getBytes` 直接回读任意 region——统一内存让"算完立刻验证"零成本。

## 5. 关键 API 与字段

```metal
kernel void grayscale_kernel(
    texture2d<float, access::read>  src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    float y = 0.299*c.r + 0.587*c.g + 0.114*c.b;
    dst.write(float4(y, y, y, 1.0), gid);
}
```

Swift 侧：`setTexture(src, index: 0)` 对应 `[[texture(0)]]`——与缓冲绑定同一套暗号体系，资源类型换了而已。

## 6. 文件结构

```
14_grayscale/
├── README.md                     # 本文档
├── grayscale.sh                  # 主演示脚本
├── main.swift                    # 入口包装：调 runGrayscale()
├── grayscale.swift               # 实验程序：compute + 渲染 + 回读验证
└── images/
    ├── grayscale.dataflow.json   # 图源
    ├── grayscale.html            # 交互版
    └── grayscale.svg             # 双主题矢量版
```

## 7. 深入要点

- **compute 访问纹理的两种方式？** read/write 逐纹素（像素对齐滤镜）与 sample 采样（缩放/插值）；本例前者。
- **为什么亮度系数不是 1/3？** 人眼对绿光最敏感（约 0.587），等权灰度会破坏亮度感知。
- **dispatch 网格怎么算？** ceil(尺寸/组大小) 向上取整，内核内边界检查——防御性写法成本为零。
- **怎么验证一个 GPU 滤镜？** shared 存储 + getBytes 回读 + 数学性质断言（灰度 = R=G=B）——把"看起来对了"变成"算出来对了"。

## 8. 总结

渲染与计算在纹理上会师。下一篇把 compute 的并行能力推向极端：一万个粒子的状态全部由 GPU 自治更新。

→ 下一篇：[15 · GPU 粒子系统](../15_particles/README.md)
