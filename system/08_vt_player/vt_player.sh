#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
BIN=".build/vt_player"
step() { echo; echo "=====> [$1] $2"; }
do_build() { step "build" "swiftc 编译"; mkdir -p .build; swiftc -O vt_player.swift -o "$BIN" 2> .build/build.log || { cat .build/build.log; exit 1; }; echo "编译完成 → $BIN"; }
do_observe() { step "observe" "Metal 滤镜视频帧处理（150 帧）"; "$BIN"; echo; echo "实验结束。"; }
do_clean() { step "clean" "清理"; rm -rf .build; echo "已清理。"; }
main() { case "${1:-all}" in build) do_build;; observe) do_observe;; clean) do_clean;; all) do_build; do_observe; do_clean;; *) echo "build|observe|clean|all";; esac; }
main "$@"
