#!/usr/bin/env bash
# 28 · 轻量推理引擎算子层 —— 主演示脚本
# 用法: ./mini_engine.sh [build | observe | clean | all]    （默认 all）
set -euo pipefail
cd "$(dirname "$0")"

BIN=".build/mini_engine"
step() { echo; echo "=====> [$1] $2"; }

do_build() {
    step "build" "swiftc -O main.swift mini_engine.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift mini_engine.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log; exit 1
    fi
    echo "编译完成 → $BIN"
}

do_observe() {
    step "observe" "5 算子注册表 + 编排执行一个 MLP"
    "$BIN"
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
