#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
BIN=".build/mp4_export"
step() { echo; echo "=====> [$1] $2"; }
do_build() { step "build" "swiftc 编译"; mkdir -p .build; swiftc -O mp4_export.swift -o "$BIN" 2> .build/build.log || { cat .build/build.log; exit 1; }; echo "编译完成 → $BIN"; }
do_observe() { step "observe" "离屏渲染 90 帧验证管线"; "$BIN"; echo; echo "实验结束。"; }
do_clean() { step "clean" "清理"; rm -rf .build; echo "已清理。"; }
main() { case "${1:-all}" in build) do_build;; observe) do_observe;; clean) do_clean;; all) do_build; do_observe; do_clean;; *) echo "build|observe|clean|all";; esac; }
main "$@"
