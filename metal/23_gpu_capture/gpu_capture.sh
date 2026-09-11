#!/usr/bin/env bash
# 23 · 帧捕获与 GPU 调试 —— 主演示脚本
# 用法: ./gpu_capture.sh [build | observe | clean | all]    （默认 all）
set -euo pipefail
cd "$(dirname "$0")"

BIN=".build/gpu_capture"
step() { echo; echo "=====> [$1] $2"; }

do_build() {
    step "build" "swiftc -O main.swift gpu_capture.swift（几秒钟）"
    mkdir -p .build
    if ! swiftc -O main.swift gpu_capture.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：程序化捕获 3 个 pass 到 .gputrace，并验证计算与文件落盘
# METAL_CAPTURE_ENABLED=1 是命令行启动时注入 Metal 捕获层的开关——
# 没有 Xcode 环境时它就是程序化捕获的前提（本实验最大的坑）
do_observe() {
    step "observe" "运行帧捕获（输出 demo_capture.gputrace，可用 Xcode 打开逐条查看 GPU 命令）"
    METAL_CAPTURE_ENABLED=1 "$BIN"
    echo
    echo "实验结束。"
}

# 清理：编译产物 + 捕获文件，目录回到实验前状态
do_clean() {
    step "clean" "删除编译产物与 demo_capture.gputrace"
    rm -rf .build demo_capture.gputrace
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
