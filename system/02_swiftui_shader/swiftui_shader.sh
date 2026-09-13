#!/usr/bin/env bash
# 02 · SwiftUI Shader 特效 —— 主演示脚本
# 用法: ./swiftui_shader.sh [build | observe | clean | all]    （默认 all）
set -euo pipefail
cd "$(dirname "$0")"

BIN=".build/swiftui_shader"
DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
step() { echo; echo "=====> [$1] $2"; }

# 创建分两步：
#   1) metal CLI 把 Effects.metal 编成 default.metallib（SwiftUI ShaderLibrary 的查找对象）
#      注：metal CLI 与 SwiftUI 头都来自完整 Xcode；SDKROOT 必须指向 Xcode SDK，
#      且 shader 函数签名要用 SwiftUI::Layer（系统 CLT SDK 缺该头）
#   2) swiftc 编译 App（-parse-as-library：单文件 @main）
# 裸二进制的 Bundle.main 是可执行文件所在目录——metallib 放在它旁边即可被找到
XSDK="/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
do_build() {
    step "build" "metal CLI 编译 Effects.metal + swiftc 编译 App"
    mkdir -p .build
    local metal
    metal=$(DEVELOPER_DIR="$DEVELOPER_DIR" /usr/bin/xcrun --find metal 2>/dev/null) || {
        echo "❌ 未找到 metal CLI（需要完整 Xcode 26）"; exit 1; }
    if ! SDKROOT="$XSDK" DEVELOPER_DIR="$DEVELOPER_DIR" "$metal" Effects.metal -o ".build/default.metallib" 2> .build/metal.log; then
        cat .build/metal.log; exit 1
    fi
    echo "Effects.metal → default.metallib"
    if ! swiftc -parse-as-library -O swiftui_shader.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log; exit 1
    fi
    swiftc -O shader_check.swift -o ".build/shader_check" 2> .build/check.log || { cat .build/check.log; exit 1; }
    echo "编译完成 → $BIN + shader_check"
}

# 观察：三个 Slider 驱动双色调/水波/故障错位；自检结果打印在控制台
do_observe() {
    step "observe" "运行实验（Slider 实时驱动三个 shader；控制台有像素级自检）"
    AUTO_QUIT="${AUTO_QUIT:-8}" "$BIN"
    step "verify" "独立自检进程：GPU 跑 duotone 与 CLI metallib 派发"
    ".build/shader_check"
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
