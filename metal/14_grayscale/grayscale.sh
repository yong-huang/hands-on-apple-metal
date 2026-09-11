#!/usr/bin/env bash
# 14 · GPU 灰度滤镜 —— 主演示脚本
# 用法: ./grayscale.sh [build | observe | clean | all]    （默认 all）
set -euo pipefail
cd "$(dirname "$0")"          # 在任意目录下运行都正确

BIN=".build/grayscale"            # 编译产物路径（clean 时整体删除）
step() { echo; echo "=====> [$1] $2"; }

# 创建：swiftc 一行编译出可执行文件，不需要 Xcode 工程——
# 着色器源码内嵌在程序里，运行时经 device.makeLibrary(source:) 由 Metal 运行时编译
do_build() {
    step "build" "swiftc -O main.swift grayscale.swift（几秒钟）"
    mkdir -p .build
    # 弃用 API 警告不影响运行；只有编译失败时才打印完整诊断
    if ! swiftc -O main.swift grayscale.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：运行实验，看 彩色测试图被 compute 逐像素转成灰度，控制台有 5 点回读验证
do_observe() {
    step "observe" "运行实验（窗口会打开；关闭窗口结束实验。脚本化运行可加前缀 AUTO_QUIT=6（秒）自动退出）"
    AUTO_QUIT="${AUTO_QUIT:-}" "$BIN"
    echo
    echo "实验结束。"
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
        clean)   do_clean ;;
        all)     do_build; do_observe; do_clean ;;
        *) echo "可用: build | observe | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
