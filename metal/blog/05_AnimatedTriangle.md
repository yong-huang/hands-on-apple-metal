# ⚡️ Metal 项目 5：动画旋转的三角形（05_AnimatedTriangle.swift）

> 所属系列：《Apple Metal 30 小项目学习清单》第一阶段「Metal 基础入门」（项目 5/30）
> 代码：`0x_learn_metal/LearnMetal/LearnMetal/Programs/05_AnimatedTriangle.swift`
> 目标：用 **Uniform Buffer（统一缓冲区）+ 矩阵变换** 让三角形绕 Z 轴持续旋转，首次引入"每帧更新 GPU 数据"的概念。

---

## 一、领域知识：为什么需要 Uniform Buffer

项目 3/4 里，顶点和颜色一动都不动——它们编译进顶点缓冲就结束了。但**真实应用 90% 的东西都在变**：旋转、位移、缩放、相机位置、逐帧时间。

把"每一帧都要变的数据"传给 GPU，Metal 的标准做法是 **Uniform Buffer**：

- 一个 `MTLBuffer`，专门存放"全局参数"（矩阵、时间、灯光……）
- 每个着色器里对应一个 `[[buffer(1)]]` 绑定槽
- CPU 每帧往这个缓冲里写新值 → GPU 下一帧读到 → 几何体就动了

本例的 Uniform 就一个成员——**模型-视图-投影矩阵**：

```swift
struct Uniforms {
    var modelViewProjectionMatrix: simd_float4x4
}
```

---

## 二、领域知识：矩阵变换（绕 Z 轴旋转）

三角形要"转起来"，本质是**把每个顶点坐标乘以一个旋转矩阵**。绕 Z 轴旋转 θ 角的矩阵：

```
| cosθ  -sinθ  0  0 |
| sinθ   cosθ  0  0 |
|   0      0   1  0 |
|   0      0   0  1 |
```

传入角度随时间线性增长，顶点就会被持续旋转：

```swift
func updateUniforms() {
    let elapsedTime = CACurrentMediaTime() - startTime!
    let angle = Float(elapsedTime) * 1.5      // 每秒转 1.5 弧度

    let rotationMatrix = simd_float4x4(
        simd_float4(cos(angle), -sin(angle), 0, 0),
        simd_float4(sin(angle),  cos(angle), 0, 0),
        simd_float4(0, 0, 1, 0),
        simd_float4(0, 0, 0, 1)
    )

    // 稍缩小，保证旋转时三角形不超出屏幕
    let scale: Float = 0.9
    let scaleMatrix = simd_float4x4(...)

    // 组合变换：先缩放后旋转
    let transformMatrix = rotationMatrix * scaleMatrix

    // 把新矩阵写进 uniform buffer（CPU→GPU）
    var uniforms = Uniforms(modelViewProjectionMatrix: transformMatrix)
    memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.size)
}
```

**注意矩阵相乘的顺序**：`rotationMatrix * scaleMatrix` 表示"先 scale 再 rotation"。MatMul 的顺序 ≠ 视觉的直觉顺序，这是 3D 数学里最常见的坑之一。

---

## 三、着色器：矩阵如何作用

`animated_vertex_main` 比项目 3 多了一个 `[[buffer(1)]]` 参数——uniform 缓冲：

```metal
struct AnimatedVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex AnimatedVertexOut animated_vertex_main(
    constant AnimatedVertexIn *vertices [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]
) {
    AnimatedVertexOut out;
    float4 position = float4(vertices[vertexID].position, 1.0);
    out.position = uniforms.modelViewProjectionMatrix * position;  // ← 关键变换
    out.color = vertices[vertexID].color;
    return out;
}
```

把顶点从 `float3` 补成 `float4`（w=1），乘上矩阵，输出变换后的裁剪坐标。**顶点着色器从此不再是"直通车"，而是一个真正的变换器**。

---

## 四、代码架构

```
runAnimatedTriangle()
└── AnimatedTriangleViewController (MTKViewDelegate)
├── viewDidLoad
│   ├── Metal → MTKView（isPaused = false 持续渲染）
│   ├── commandQueue / setupPipeline / setupVertexData
│   ├── setupUniformBuffer()   创建 16 字节 float4x4 缓冲，初始为单位阵
│   └── startTime = CACurrentMediaTime()   记录动画起点
├── updateUniforms() 每帧计算旋转+缩放矩阵 → memcpy 进 uniform buffer
└── draw(in:)  每帧：updateUniforms → 编码 → 绑定 → drawPrimitives(.triangle, 3) → present
```

与项目 3 的差分非常「教学式」：

| | 项目 3 | 项目 5 |
|:---|:---|:---|
| 顶点数据 | 顶点 + 颜色 | 顶点 + 颜色（不变） |
| 每帧变化 | 无 | uniform 矩阵 |
| 着色器 | 直通颜色 | 顶点乘矩阵变换 |
| 多出的步骤 | — | `setupUniformBuffer` + `updateUniforms` |

**旋转不是改顶点数据，而是改 uniform。** 顶点缓冲一生只上传一次，变换由每帧的矩阵驱动——这正是现代引擎"网格静态、变换动态"的雏形。

---

## 五、运行方式

```swift
// main.swift
print("=== Running Animated Triangle ===")
runAnimatedTriangle()
```

窗口标题 `Animating Triangle (MVP Matrix)`，三角形的三种颜色随旋转平滑转动，每秒约 86°。

---

## 六、延伸思考

- **为什么把矩阵放在 uniform 而不是改写顶点缓冲？** 顶点缓冲在 GPU 内存里重传很贵；矩阵数据小、更新快、CPU/GPU 同时可见（`.storageModeShared`），是"每帧动态数据"的最优解。
- **`CACurrentMediaTime` vs `Date`**：前者基于单调时钟，不受系统时间调整影响，是做动画计时、避免漂移的标准选择。
- **下一步**：有了矩阵，就能做真正的 3D——透视投影矩阵、相机（view matrix）、立方体（多个面）。项目 5 完成，Metal 基础的"手"已经齐全：顶点、索引、着色器、uniform、矩阵、动画。
- 从项目 6 开始进入**阶段二「着色器特效」**，图形将不再依赖顶点颜色，而是由**片元着色器从零计算**每个像素。

---

*系列：《Apple Metal 30 小项目》· 第一阶段：基础入门（完成 1-5）→ 下一阶段：着色器特效（6-9）*