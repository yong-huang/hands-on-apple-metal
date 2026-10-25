#!/usr/bin/env bash
# 01 · 极光渐变板 Plasma —— 主演示脚本
# 用法: ./plasma.sh [build | observe | clean | export <file.png> [palette] | all]    （默认 all）
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

BIN=".build/plasma"            # 编译产物路径（clean 时整体删除）
step() { echo; echo "=====> [$1] $2"; }

# 产物缺失或任一 Swift 源码比产物新时需要重建（防止 observe 跑到陈旧二进制）
needs_build() {
    [ ! -x "$BIN" ] && return 0
    local src
    for src in main.swift *.swift; do
        [ "$src" -nt "$BIN" ] && return 0
    done
    return 1
}

# 创建：swiftc 一行编译出可执行文件，不需要 Xcode 工程——
# 着色器源码内嵌在程序里，运行时经 device.makeLibrary(source:) 由 Metal 运行时编译
do_build() {
    step "build" "swiftc -O main.swift plasma.swift（几秒钟）"
    mkdir -p .build
    # 只有编译失败时才打印完整诊断
    if ! swiftc -O main.swift plasma.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log
        exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：运行实验，看 多组正弦叠加的流动色场（C 键循环切换 极光/晚霞/深海 三套配色）
# 产物缺失时自动先构建——observe 单独使用也能在全新目录直接跑通
do_observe() {
    if needs_build; then
        do_build
    fi
    step "observe" "运行实验（窗口会打开；关闭窗口结束实验。脚本化运行可加前缀 AUTO_QUIT=6（秒）自动退出）"
    AUTO_QUIT="${AUTO_QUIT:-}" "$BIN"
    echo
    echo "实验结束。"
}

# 导出：离屏渲染一帧写 PNG（不开窗口，无人值守验收用）
do_export() {
    local file; file=$(resolve_path "${1:-plasma.png}")
    local palette="${2:-1}"
    do_build
    # 注意：$file 后紧跟全角（ 会让 macOS 自带 bash 3.2 把多字节首字节并进变量名，
    # 报 "file: unbound variable"——变量名后紧跟非 ASCII 字符必须写 ${file} 定界
    step "export" "离屏渲染 1920×1080 一帧 → ${file}（配色 ${palette}，无窗口）"
    "$BIN" export "$file" "$palette"
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
        export)  shift; do_export "${1:-plasma.png}" "${2:-1}" ;;
        all)     do_build; do_observe; do_clean ;;
        *) echo "可用: build | observe | clean | export <file.png> [palette] | all" >&2; exit 1 ;;
    esac
}
main "$@"
