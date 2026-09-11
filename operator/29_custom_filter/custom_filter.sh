#!/usr/bin/env bash
# 29 · 自定义图像算子 —— 主演示脚本
# 用法: ./custom_filter.sh [build | observe | clean | all]    （默认 all）
set -euo pipefail
cd "$(dirname "$0")"

BIN=".build/custom_filter"
step() { echo; echo "=====> [$1] $2"; }

do_build() {
    step "build" "swiftc -O main.swift custom_filter.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift custom_filter.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log; exit 1
    fi
    echo "编译完成 → $BIN"
}

do_observe() {
    step "observe" "自定义风格化滤镜接入 MPS 流水线"
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
