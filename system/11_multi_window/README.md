# 11 · 多窗口渲染：同一渲染器驱动多窗口
> 两个 SwiftUI 窗口各挂一个 CAMetalLayer，渲染同一场景的不同色调。关掉一个另一个不掉帧。
## 1. 核心概念
单例 `SharedRenderer` 共享 Device/Pipeline；每个窗口独立 DisplayLink + CAMetalLayer。
## 2. 快速开始
```bash
./multi_window.sh
```
## 3. 文件结构
```
11_multi_window/
├── README.md
├── multi_window.sh
├── multi_window.swift
└── images/ (三件套)
```
## 4. 深入要点
- 单例模式共享 Metal 资源，避免重复创建
- 各窗口独立帧率，互不阻塞
→ 返回清单：[metal_system.md](../../metal_system.md)
