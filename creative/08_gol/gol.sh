#!/usr/bin/env bash
# 08 · GPU 生命游戏 —— 主演示脚本
# 用法: ./gol.sh [build | observe | bench | test | export <file.png> [seed gens] | clean | all]    （默认 all）
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

BIN=".build/gol"               # 编译产物路径（clean 时整体删除）
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
    step "build" "swiftc -O main.swift gol.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift gol.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：点击/拖拽播种，空格暂停，R 随机重置
# 产物缺失或源码更新时自动先构建
do_observe() {
    if needs_build; then
        do_build
    fi
    step "observe" "运行实验（点击播种 · 空格暂停 · R 重置；AUTO_QUIT=秒数 可自动退出）"
    AUTO_QUIT="${AUTO_QUIT:-}" "$BIN"
    echo
    echo "实验结束。"
}

# 验收基准：1024×1024 跑 100 代计时（单代预算 16.6ms，对应 60 FPS）
do_bench() {
    if needs_build; then
        do_build
    fi
    step "bench" "1024×1024 跑 100 代，计时（单代预算 16.6 ms）"
    "$BIN" bench
}

# 验收测试：Glider 从 (10,10) 跑 100 代，回读纹理验证平移 25 格
do_test() {
    if needs_build; then
        do_build
    fi
    step "test" "Glider 100 代平移验证（预期包围盒 (35,35)–(37,37)）"
    "$BIN" test
}

# 导出：固定 seed 演化 N 代后写 PNG。参数: export <file.png> [seed gens]
do_export() {
    local file; file=$(resolve_path "${1:-gol.png}")
    do_build
    step "export" "离屏演化并导出 1024×1024 → ${file}"
    "$BIN" export "$file" "${2:-1.0}" "${3:-200}"
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
        test)    do_test ;;
        export)  shift; do_export "$@" ;;
        clean)   do_clean ;;
        all)     do_build; do_observe; do_clean ;;
        *) echo "可用: build | observe | bench | test | export <file.png> [seed gens] | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
