#!/usr/bin/env bash
# 02 · 分形探险家 Mandelbrot/Julia —— 主演示脚本
# 用法: ./fractal.sh [build | observe | clean | export <file.png> [re im scale [jre jim]] | all]    （默认 all）
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

BIN=".build/fractal"           # 编译产物路径（clean 时整体删除）
step() { echo; echo "=====> [$1] $2"; }

# 产物缺失或任一 Swift 源码比产物新时需要重建（防止 observe 跑到陈旧二进制）
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
    step "build" "swiftc -O main.swift fractal.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift fractal.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：滚轮缩放、拖拽平移、点击切换 Julia、R 复位
# 产物缺失时自动先构建——observe 单独使用也能在全新目录直接跑通
do_observe() {
    if needs_build; then
        do_build
    fi
    step "observe" "运行实验（滚轮缩放 · 拖拽平移 · 点击切 Julia · R 复位；AUTO_QUIT=秒数 可自动退出）"
    AUTO_QUIT="${AUTO_QUIT:-}" "$BIN"
    echo
    echo "实验结束。"
}

# 导出：离屏渲染一帧写 PNG（不开窗口，无人值守验收用）
# 参数: export <file.png> [re im scale [jre jim]]——中心复数与纵向覆盖；
#       给足 6/7 个参数时渲染 Julia 集（c = jre+jim），默认 Mandelbrot 全景
do_export() {
    local file; file=$(resolve_path "${1:-fractal.png}")
    do_build
    if [ "$#" -ge 6 ]; then
        step "export" "离屏渲染 1920×1080 一帧 → ${file}（Julia c=${5}+${6}i，纵向覆盖 ${4}）"
        "$BIN" export "$file" "${2:--0.6}" "${3:-0.0}" "${4:-2.5}" "$5" "$6"
    else
        local re="${2:--0.6}"
        local im="${3:-0.0}"
        local scale="${4:-2.5}"
        step "export" "离屏渲染 1920×1080 一帧 → ${file}（中心 ${re}+${im}i，纵向覆盖 ${scale}）"
        "$BIN" export "$file" "$re" "$im" "$scale"
    fi
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
        export)  shift; do_export "$@" ;;
        all)     do_build; do_observe; do_clean ;;
        *) echo "可用: build | observe | clean | export <file.png> [re im scale [jre jim]] | all" >&2; exit 1 ;;
    esac
}
main "$@"
