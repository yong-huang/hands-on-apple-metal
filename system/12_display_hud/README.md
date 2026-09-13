# 12 · 帧率 HUD：帧时间曲线画进 Metal
> 用 Metal 自绘 HUD 叠加在渲染画面上，实时显示最近 120 帧耗时。人为 sleep 可看到尖刺。
## 1. 核心概念
两个 Pass：Pass1 场景渲染，Pass2 HUD 帧时间曲线（`lineStrip`）。
## 2. 快速开始
```bash
./display_hud.sh
```
## 3. 文件结构
```
12_display_hud/
├── README.md
├── display_hud.sh
├── display_hud.swift
└── images/ (三件套)
```
## 4. 深入要点
- HUD 显示最近 120 帧耗时曲线，可实时观察卡顿
- 人为 sleep 可看到尖刺——性能分析可视化
→ 返回清单：[metal_system.md](../../metal_system.md)
