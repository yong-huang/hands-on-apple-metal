# 08 · Metal 滤镜视频帧处理

> 生成 150 帧 640×360 测试图案 → Metal compute 逐帧饱和度滤镜 → GPU 回读验证。
> 演示 Metal 在视频帧处理管线中的正确用法。

## 1. 为什么需要它
视频处理（滤镜/调色/AI 增强）是 GPU 非计算密集场景的典型应用。

## 2. 总览：核心机制一图看懂
![视频帧处理数据流](images/vt_player.svg)
> 🌐 **交互版**：[在线打开](https://yong-huang.github.io/hands-on-metal/system/08_vt_player/images/vt_player.html)

## 3. 快速开始
```bash
./vt_player.sh
```
真实输出：
```
处理完成: 150 帧 / 0.17 秒 = 860 fps
✅ 验证通过：150 帧全部正确处理
```

## 4. 核心概念
- `texture2d<half, access::read/write>` compute 内核的标准纹理访问模式
- `rgba8Unorm` 格式下 read 自动转换为 half4
- dispatch 网格 = ceil(宽/16) × ceil(高/16)

## 5. 关键代码
```metal
kernel void saturate(texture2d<half, access::read> src [[texture(0)]],
                     texture2d<half, access::write> dst [[texture(1)]],
                     constant float& sat [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    half4 c = src.read(gid);
    half avg = (c.r + c.g + c.b) / 3.0h;
    dst.write(half4(half3(avg) + (c.rgb - half3(avg)) * half(sat), 1.0h), gid);
}
```

## 6. 文件结构
```
08_vt_player/
├── README.md
├── vt_player.sh
├── vt_player.swift
└── images/ (三件套)
```

## 7. 深入要点
- shared 模式的 getBytes 需要 GPU→CPU 同步
- dispatch 网格 ceil(宽/16) × ceil(高/16) 是通用选择

## 8. 总结
Metal 在视频帧处理管线中的用法验证通过。
→ 返回清单：[metal_system.md](../../metal_system.md)
