#!/usr/bin/env bash
# 01 · 脱离 MTKView：直接驱动 CAMetalLayer —— 主演示脚本
# 用法: ./cametal_layer.sh [build | observe | clean | all]    （默认 all）
set -euo pipefail
cd "$(dirname "$0")"

BIN=".build/cametal_layer"
step() { echo; echo "=====> [$1] $2"; }

# @main App 单文件编译（无 main.swift，Swift 自动合成入口）
do_build() {
    step "build" "swiftc -parse-as-library -O cametal_layer.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -parse-as-library -O cametal_layer.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log; exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：SwiftUI 窗口内渐变流动，每秒打印 fps；AUTO_QUIT=<秒> 自动退出
do_observe() {
    step "observe" "运行实验（窗口会打开；每秒打印 fps。脚本化运行可加前缀 AUTO_QUIT=6）"
    AUTO_QUIT="${AUTO_QUIT:-5}" "$BIN"
    echo
    echo "实验结束。"
}

do_clean() {
    step "clean" "删除编译产物"
    rm -rf .build
    echo "已清理。"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        build)   do_build ;;
        observe) do_observe ;;
        clean)   do_clean ;;
        all)     do_build; do_observe; do_clean ;;
        *) echo "可用: build | observe | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
