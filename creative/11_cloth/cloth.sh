#!/usr/bin/env bash
# 11 · 可撕裂布料 —— 主演示脚本
# 用法: ./cloth.sh [build | observe | test | bench | export <file.png> [pullFrames] | clean | all]    （默认 all）
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

BIN=".build/cloth"             # 编译产物路径（clean 时整体删除）
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
    step "build" "swiftc -O main.swift cloth.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift cloth.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：拖拽布面 · 用力甩撕开它
# 产物缺失或源码更新时自动先构建
do_observe() {
    if needs_build; then
        do_build
    fi
    step "observe" "运行实验（拖拽甩动撕开；AUTO_QUIT=秒数 可自动退出）"
    AUTO_QUIT="${AUTO_QUIT:-}" "$BIN"
    echo
    echo "实验结束。"
}

# 验收测试：静置稳定性 + 强拉撕裂有界
do_test() {
    if needs_build; then
        do_build
    fi
    step "test" "无人值守两条验收断言（稳定性 + 撕裂有界）"
    "$BIN" test
}

# 性能基准：物理单帧计时
do_bench() {
    if needs_build; then
        do_build
    fi
    step "bench" "物理单帧计时（预算 16.6 ms）"
    "$BIN" bench
}

# 导出：渲染一帧写 PNG。参数: export <file.png> [pullFrames]（0=静置，>0=先拉扯再导出撕裂态）
do_export() {
    local file; file=$(resolve_path "${1:-cloth.png}")
    do_build
    step "export" "离屏渲染 800×600 → ${file}（拉扯 ${2:-0} 帧）"
    "$BIN" export "$file" "${2:-0}"
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
        test)    do_test ;;
        bench)   do_bench ;;
        export)  shift; do_export "$@" ;;
        clean)   do_clean ;;
        all)     do_build; do_observe; do_clean ;;
        *) echo "可用: build | observe | test | bench | export <file.png> [pullFrames] | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
