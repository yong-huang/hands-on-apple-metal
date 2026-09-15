# 09 · Metal 离屏渲染帧序列

> 90 帧离屏渲染 → 逐帧回读 → 像素校验。演示 Metal 离屏渲染管线的正确用法。

## 1. 为什么需要它
离屏渲染是 Metal 后处理、视频导出、AI 推理输入的基建。

## 2. 总览
![离屏渲染数据流](images/mp4_export.svg)
> 🌐 **交互版**：[在线打开](https://yong-huang.github.io/hands-on-apple-metal/system/09_mp4_export/images/mp4_export.html)

## 3. 快速开始
```bash
./mp4_export.sh
```

## 4. 核心概念
- 离屏纹理 `storageMode = .shared` 允许 CPU getBytes 回读
- 逐帧渲染 + 回读验证像素非零

## 5. 关键代码
```swift
let td = MTLTextureDescriptor.texture2DDescriptor(...)
td.usage = [.renderTarget, .shaderRead]
td.storageMode = .shared
```

## 6. 文件结构
```
09_mp4_export/
├── README.md
├── mp4_export.sh
├── mp4_export.swift
└── images/ (三件套)
```

## 7. 深入要点
- shared 模式的 getBytes 需要 GPU→CPU 同步
- 生产环境应批量回读或用 blit encoder

## 8. 总结
离屏渲染验证通过，为后续视频导出管线打好基础。
→ 返回清单：[metal_system.md](../../docs/metal_system.md)
