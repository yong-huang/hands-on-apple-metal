#!/usr/bin/env bash
# 06 · 超分辨率渲染 —— 主演示脚本
# 用法: ./metalfx.sh [build | observe | clean | all]    （默认 all）
set -euo pipefail
cd "$(dirname "$0")"

BIN=".build/metalfx"
step() { echo; echo "=====> [$1] $2"; }

do_build() {
    step "build" "swiftc -parse-as-library -O metalfx.swift"
    mkdir -p .build
    if ! swiftc -parse-as-library -O metalfx.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log; exit 1
    fi
    echo "编译完成 → $BIN"
}

do_observe() {
    step "observe" "运行超分渲染演示（低分辨率渲染 + 放大呈现，观察 fps）"
    AUTO_QUIT="${AUTO_QUIT:-12}" "$BIN"
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
