#!/usr/bin/env bash
# 09 · 打砖块 Breakout —— 主演示脚本
# 用法: ./breakout.sh [build | observe | test | export <file.png> | clean | all]    （默认 all）
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

BIN=".build/breakout"          # 编译产物路径（clean 时整体删除）
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
    step "build" "swiftc -O main.swift breakout.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift breakout.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：鼠标控拍 · 点击发射 · R 重开
# 产物缺失或源码更新时自动先构建
do_observe() {
    if needs_build; then
        do_build
    fi
    step "observe" "运行实验（鼠标控拍 · 点击发射 · R 重开；AUTO_QUIT=秒数 可自动退出）"
    AUTO_QUIT="${AUTO_QUIT:-}" "$BIN"
    echo
    echo "实验结束。"
}

# 验收测试：断言一 自动追踪 AI 通关；断言二 空闲拍恰丢 3 命
do_test() {
    if needs_build; then
        do_build
    fi
    step "test" "无人值守两条验收断言（通关 + 丢命状态机）"
    "$BIN" test
}

# 导出：开局画面写 PNG
do_export() {
    local file; file=$(resolve_path "${1:-breakout.png}")
    do_build
    step "export" "离屏渲染开局画面 800×600 → ${file}"
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
        test)    do_test ;;
        export)  shift; do_export "${1:-breakout.png}" ;;
        clean)   do_clean ;;
        all)     do_build; do_observe; do_clean ;;
        *) echo "可用: build | observe | test | export <file.png> | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
