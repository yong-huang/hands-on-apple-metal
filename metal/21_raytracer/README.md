# 21 · 光线追踪：MPSRayIntersector

> 光栅化问"每个三角形盖住哪些像素"，光线追踪问"每个像素看到了谁"。
> 视角一换，反射、折射、软阴影都变成自然推论。
> 本实验用 MPS 加速结构做真·光线追踪：26 万根光线，命中率高到可统计。

## 1. 为什么需要它

光线追踪是渲染的两极之一，也是 Metal Performance Shaders 最"高冷"的模块。跑通"生成光线 → 加速求交 → 着色"的最小闭环，未来反射/阴影/全局光都只是"再发几根光线"的增量工作。

## 2. 总览：核心机制一图看懂

![光线追踪数据流](images/raytracer.svg)

> 🌐 **交互版**：[在线打开（GitHub Pages）](https://yong-huang.github.io/hands-on-metal/metal/21_raytracer/images/raytracer.html)（或本地打开 [`images/raytracer.html`](images/raytracer.html)）。

针孔相机生成 26 万根主光线，MPS 加速结构求最近交点，CPU 按重心坐标插值着色。一句话心智模型：**每个像素发射一根问题，场景回答"撞到哪、撞到谁"**。

## 3. 快速开始

```bash
./raytracer.sh               # 一条龙
AUTO_QUIT=6 ./raytracer.sh observe
```

真实输出：

```
光追完成: 262144 根光线，命中 163026 根（命中率 62.2%）
  采样中心(256,256) = [147, 183, 76] ✅ 命中场景
  采样角落(4,4) = [14, 17, 28] ✅ 未命中(背景)
✅ 光线追踪验证通过
```

窗口显示两个彩色三角形的光追成像。验证方法：命中率可由场景张角解析估算；中心必命中、角落必是背景色。

## 4. 核心概念

### 4.1 Swift 侧布局镜像（本实验最大的坑）

ray / intersection 结构体只定义在 MSL 头文件里，Swift 必须手写**内存布局一致**的镜像：

```swift
struct Ray  { var origin: SIMD3<Float>; var direction: SIMD3<Float> }              // .originDirection
struct Hit  { var distance: Float; var primitiveIndex: UInt32; var coordinates: SIMD2<Float> }  // .distancePrimitiveIndexCoordinates
```

未命中时 `distance = -1`、`primitiveIndex = 0xFFFFFFFF`——这两个哨兵值是实测确定的。

### 4.2 加速结构只吃位置

`MPSTriangleAccelerationStructure.vertexBuffer` 要求紧凑的 float3 位置数组。第一次实现把颜色混进顶点结构，三角形变成乱数据、命中结果全部错误且**不报错**——布局契约必须严格遵守。

### 4.3 重心坐标着色

交点携带 `coordinates`：按 Apple 约定 `w0 = 1−x−y, w1 = x, w2 = y`，颜色 = 三个顶点色的加权和——与光栅化插值同一套数学。

### 4.4 易错点

- 枚举名记错：ray 类型叫 `.originMinDistanceDirectionMaxDistance` 而不是文档示例的简写。
- 交点结构体字段顺序按名字想当然（distance 在前），读出"基本索引"实为浮点位模式。

## 5. 关键 API 与字段

```swift
intersector.rayDataType = .originDirection
intersector.intersectionDataType = .distancePrimitiveIndexCoordinates
intersector.encodeIntersection(commandBuffer: cb, intersectionType: .nearest,
    rayBuffer: rayBuffer, rayBufferOffset: 0, intersectionBuffer: interBuffer,
    intersectionBufferOffset: 0, rayCount: W * H, accelerationStructure: accel)
```

编码进普通 compute encoder，`waitUntilCompleted` 后交点数据即可 CPU 读取。

## 6. 文件结构

```
21_raytracer/
├── README.md                    # 本文档
├── raytracer.sh                 # 主演示脚本
├── main.swift                   # 入口包装：调 runRaytracer()
├── raytracer.swift              # 实验程序：相机/加速结构/求交/CPU 着色
└── images/
    ├── raytracer.dataflow.json  # 图源
    ├── raytracer.html           # 交互版
    └── raytracer.svg            # 双主题矢量版
```

## 7. 面试要点

- **光线追踪 vs 光栅化的本质区别？** 反向遍历问题域：屏幕→场景 vs 场景→屏幕；决定各自擅长效果（反射/精确遮挡 vs 速度）。
- **加速结构解决什么？** 暴力求交 O(光线×三角形)；BVH 类结构把查询降到对数级。
- **重心坐标的用途？** 交点在三角形内的位置参数化，用于插值任意顶点属性（颜色/法线/UV）。
- **MPSRayIntersector 与自写 BVH 的取舍？** MPS 免维护、有苹果级调优；自写可定制几何/遍历策略。原型期用 MPS 是正解。

## 8. 总结

光追闭环打通，MPS 家族初体验。下一篇回到光栅化，解决另一个极端问题：怎么用一次 draw 画 400 个物体。

→ 下一篇：[22 · 实例化渲染](../22_instancing/README.md)
