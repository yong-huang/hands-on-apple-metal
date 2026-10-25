#!/usr/bin/env bash
# 05 · 图灵花纹 Gray-Scott 反应扩散 —— 主演示脚本
# 用法: ./turing.sh [build | observe | bench | export <file.png> [F k seed steps] | clean | all]    （默认 all）
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

BIN=".build/turing"            # 编译产物路径（clean 时整体删除）
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
    step "build" "swiftc -O main.swift turing.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift turing.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：条纹/斑点实时演化；←→ 调 F，↑↓ 调 k，B 切边界，R 重播
# 产物缺失或源码更新时自动先构建
do_observe() {
    if needs_build; then
        do_build
    fi
    step "observe" "运行实验（←→ 调 F · ↑↓ 调 k · B 切边界 · R 重播；AUTO_QUIT=秒数 可自动退出）"
    AUTO_QUIT="${AUTO_QUIT:-}" "$BIN"
    echo
    echo "实验结束。"
}

# 验收基准：512×512 网格 1000 步纯 compute 计时
do_bench() {
    if needs_build; then
        do_build
    fi
    step "bench" "512×512 跑 1000 步，计时（验收线 1000 ms）"
    "$BIN" bench
}

# 导出：指定参数离屏演化到稳定态后写 PNG。参数: export <file.png> [F k seed steps boundary]
do_export() {
    local file; file=$(resolve_path "${1:-turing.png}")
    do_build
    step "export" "离屏演化并导出 1024×1024 → ${file}"
    "$BIN" export "$@"   # "$@" 全量转发，F/k/seed/steps/boundary 的默认值由程序自己兜底
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
        bench)   do_bench ;;
        export)  shift; do_export "$@" ;;
        clean)   do_clean ;;
        all)     do_build; do_observe; do_clean ;;
        *) echo "可用: build | observe | bench | export <file.png> [F k seed steps] | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
