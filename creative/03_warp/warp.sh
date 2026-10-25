#!/usr/bin/env bash
# 03 · Domain Warping 壁纸生成器 —— 主演示脚本
# 用法: ./warp.sh [build | clean | export <file.png> [seed] | seeds <file.png> | all]    （默认 all）
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

BIN=".build/warp"              # 编译产物路径（clean 时整体删除）
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
    step "build" "swiftc -O main.swift warp.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift warp.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 导出：4K 离屏渲染一张壁纸 PNG。参数: export <file.png> [seed]
do_export() {
    local file; file=$(resolve_path "${1:-warp.png}")
    local seed="${2:-1.0}"
    do_build
    step "export" "离屏渲染 3840×2160 一帧 → ${file}（seed ${seed}，无窗口）"
    "$BIN" export "$file" "$seed"
}

# 三连导出：三个不同 seed 各出一张，验收"换 seed 换图"
do_seeds() {
    local prefix="${1:-warp}"
    do_build
    local s
    for s in 1.0 7.0 42.0; do
        step "export" "离屏渲染 3840×2160 一帧 → ${prefix}_${s}.png（seed ${s}）"
        "$BIN" export "${prefix}_${s}.png" "$s"
    done
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
        clean)   do_clean ;;
        export)  shift; do_export "${1:-warp.png}" "${2:-1.0}" ;;
        seeds)   shift; do_seeds "${1:-warp}" ;;
        all)     do_build; do_seeds "warp"; do_clean ;;
        *) echo "可用: build | clean | export <file.png> [seed] | seeds <prefix> | all" >&2; exit 1 ;;
    esac
}
main "$@"
