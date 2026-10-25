#!/usr/bin/env bash
# 01 · Necker 立方体 —— 主演示脚本
# 用法: ./necker.sh [build | observe | clean | export <file.png> [a|b] | all]    （默认 all）
set -euo pipefail

ORIG_PWD="$PWD"                 # 记录运行脚本时的目录：导出的相对路径按它解析，而不是脚本内的 cd
cd "$(dirname "$0")"            # 在任意目录下运行都正确

# 相对路径 → 基于 ORIG_PWD 的绝对路径；绝对路径原样返回
resolve_path() {
    case "$1" in
        /*) echo "$1" ;;
        *) echo "$ORIG_PWD/$1" ;;
    esac
}

BIN=".build/necker"             # 编译产物路径（clean 时整体删除）
step() { echo; echo "=====> [$1] $2"; }

# 产物缺失或任一 Swift 源码比产物新时需要重建
needs_build() {
    [ ! -x "$BIN" ] && return 0
    local src
    for src in main.swift *.swift; do
        [ "$src" -nt "$BIN" ] && return 0
    done
    return 1
}

# 创建：swiftc 一行编译出可执行文件；着色器源码内嵌，运行时由 Metal 编译
do_build() {
    step "build" "swiftc -O main.swift necker.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift necker.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：自由旋转 + 滚轮缩放，F 切换两种深度解读，重置回魔法角度；帧率见窗口标题栏
# 产物缺失或源码更新时自动先构建
do_observe() {
    if needs_build; then
        do_build
    fi
    step "observe" "运行实验（自由旋转 · 滚轮缩放 · F 切换解读；AUTO_QUIT=秒数 可自动退出）"
    AUTO_QUIT="${AUTO_QUIT:-}" "$BIN"
    echo
    echo "实验结束。"
}

# 导出：固定魔法角度离屏渲染一帧写 PNG（解读 a=左下面在前 / b=右上面在前）
do_export() {
    local file; file=$(resolve_path "${1:-necker.png}")
    local mode="${2:-a}"
    do_build
    step "export" "离屏渲染 1920×1080 一帧 → ${file}（解读 ${mode}，固定视角，无窗口）"
    "$BIN" export "$file" "$mode"
}

# 清理：删除编译产物，目录回到实验前状态
do_clean() {
    step "clean" "删除 $(basename "$BIN") 等编译产物"
    rm -rf .build
    echo "已清理。"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        build)   do_build ;;
        observe) do_observe ;;
        clean)   do_clean ;;
        export)  shift; do_export "${1:-necker.png}" "${2:-a}" ;;
        all)     do_build; do_observe; do_clean ;;
        *) echo "可用: build | observe | clean | export <file.png> [a|b] | all" >&2; exit 1 ;;
    esac
}
main "$@"
