#!/usr/bin/env bash
# 06 · SDF Raymarching 小场景 —— 主演示脚本
# 用法: ./raymarch.sh [build | observe | clean | export <file.png> | all]    （默认 all）
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

BIN=".build/raymarch"          # 编译产物路径（clean 时整体删除）
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
    step "build" "swiftc -O main.swift raymarch.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift raymarch.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：拖拽旋转轨道相机，看软阴影与 AO；帧率见窗口标题栏
# 产物缺失或源码更新时自动先构建
do_observe() {
    if needs_build; then
        do_build
    fi
    step "observe" "运行实验（拖拽旋转视角；AUTO_QUIT=秒数 可自动退出）"
    AUTO_QUIT="${AUTO_QUIT:-}" "$BIN"
    echo
    echo "实验结束。"
}

# 导出：固定相机角度离屏渲染一帧写 PNG
do_export() {
    local file; file=$(resolve_path "${1:-raymarch.png}")
    do_build
    step "export" "离屏渲染 1920×1080 一帧 → ${file}（固定视角，无窗口）"
    "$BIN" export "$file"
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
        export)  shift; do_export "${1:-raymarch.png}" ;;
        all)     do_build; do_observe; do_clean ;;
        *) echo "可用: build | observe | clean | export <file.png> | all" >&2; exit 1 ;;
    esac
}
main "$@"
