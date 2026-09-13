#!/usr/bin/env bash
# 04 · 三路推理基准 —— 主演示脚本
# 用法: ./ane_bench.sh [build | observe | clean | all]    （默认 all）
set -euo pipefail
cd "$(dirname "$0")"

PY=~/.venvs/ml/bin/python     # coremltools 9.0 所在 venv
BIN=".build/ane_bench"
step() { echo; echo "=====> [$1] $2"; }

# 创建：① coremltools 生成 784-256-10 模型 ② swiftc 编译基准程序
do_build() {
    step "build" "gen_model.py 生成模型 + swiftc 编译基准"
    "$PY" gen_model.py 2>&1 | grep -vE "Failed to load|Fail to import" || true
    test -d Model.mlpackage || { echo "❌ 模型生成失败"; exit 1; }
    mkdir -p .build
    if ! swiftc -O ane_bench.swift -o "$BIN" 2> .build/build.log; then
        cat .build/build.log; exit 1
    fi
    echo "编译完成 → $BIN"
}

# 观察：三路各 100 次推理，输出延迟对照表
do_observe() {
    step "observe" "三路推理基准（GPU/ANE/CPU 各 100 次，预热 10 次）"
    "$BIN"
    echo
    echo "实验结束。"
}

do_clean() {
    step "clean" "删除编译产物与模型"
    rm -rf .build Model.mlpackage
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
