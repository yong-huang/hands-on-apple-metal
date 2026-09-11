#!/usr/bin/env bash
# op 18_softmax —— 主演示脚本
# 用法: ./softmax.sh [run | clean | all]    （默认 all）
set -euo pipefail
cd "$(dirname "$0")"

step() { echo; echo "=====> [$1] $2"; }

do_run() {
    step "run" "MLX 实验跑通"
    python3 -c "import mlx.core" 2>/dev/null || { echo "❌ 缺少 MLX：pip3 install --break-system-packages mlx"; exit 1; }
    python3 softmax.py
    echo
    echo "实验结束。"
}

do_clean() {
    step "clean" "清理 __pycache__ 与输出文件"
    rm -rf __pycache__ .output
    echo "已清理。"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        run)   do_run ;;
        clean) do_clean ;;
        all)   do_run; do_clean ;;
        *) echo "可用: run | clean | all" >&2; exit 1 ;;
    esac
}
main "$@"
