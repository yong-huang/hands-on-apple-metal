#!/usr/bin/env bash
# 01 · 抛体运动——真空与空气阻力 —— 主演示脚本
# 用法: ./projectile.sh [build | observe | verify | export <file.png> | clean | all]    （默认 all）
set -euo pipefail

ORIG_PWD="$PWD"                 # 记录运行脚本时的目录：脚本内 cd 不影响外部相对路径
cd "$(dirname "$0")"            # 在任意目录下运行都正确

BIN=".build/projectile"         # 编译产物路径（clean 时整体删除）
step() { echo; echo "=====> [$1] $2"; }

# 产物缺失或任一 Swift 源码比产物新时需要重建（防止 observe 跑到陈旧二进制）
needs_build() {
    [ ! -x "$BIN" ] && return 0
    local src
    for src in main.swift projectile.swift; do
        [ "$src" -nt "$BIN" ] && return 0
    done
    return 1
}

# 创建：swiftc 一行编译出可执行文件，不需要 Xcode 工程——
# 着色器源码内嵌在程序里，运行时经 device.makeLibrary(source:) 由 Metal 运行时编译
do_build() {
    step "build" "swiftc -O main.swift projectile.swift（几秒钟）"
    mkdir -p .build
    # 只有编译失败时才打印完整诊断
    if ! swiftc -O main.swift projectile.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：同屏看 真空（白）/ 空气阻力（橙）两条轨迹，按键实时调参看射程怎么变
# 产物缺失或源码更新时自动先构建——observe 单独使用也能在全新目录直接跑通
do_observe() {
    if needs_build; then
        do_build
    fi
    step "observe" "运行实验（←→ 初速 ↑↓ 射角 D 阻力 T 对照表 R 重置；前缀 AUTO_QUIT=秒数 可自动退出并打印对照表）"
    AUTO_QUIT="${AUTO_QUIT:-}" "$BIN"
    echo
    echo "实验结束。"
}

# 定量验收：无窗口跑 11 条断言——真空射程 vs v²sin(2θ)/g 误差 <1%、
# 真空最优角 45°、阻力最优角 <45° 且随 c 单调前移。exit 0 = 全过
do_verify() {
    if needs_build; then
        do_build
    fi
    step "verify" "无窗口定量验收：模拟值 vs 教科书公式对照表（11 条断言）"
    "$BIN" verify
}

# 导出：离屏渲染一帧写 PNG（不开窗口，视觉核对与验收截图用）
do_export() {
    if needs_build; then
        do_build
    fi
    local file; file="${1:-projectile.png}"
    step "export" "离屏渲染 1440×900 一帧 → $file（默认参数，无窗口）"
    "$BIN" export "$file"
}

# 清理：删除编译产物，目录回到实验前状态
do_clean() {
    step "clean" "删除 .build/ 编译产物"
    rm -rf .build
    echo "已清理。"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        build)   do_build ;;
        observe) do_observe ;;
        verify)  do_verify ;;
        export)  shift; do_export "${1:-projectile.png}" ;;
        clean)   do_clean ;;
        all)     do_build; do_verify; do_observe; do_clean ;;
        *) echo "可用: build | observe | verify | export <file.png> | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
