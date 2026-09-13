#!/usr/bin/env bash
set -euo pipefail; cd "$(dirname "$0")"
BIN=".build/display_hud"
step() { echo; echo "=====> [$1] $2"; }
do_build() { step "build" "swiftc"; mkdir -p .build; swiftc -parse-as-library -O display_hud.swift -o "$BIN" 2> .build/build.log || { cat .build/build.log; exit 1; }; echo OK; }
do_observe() { step "observe" "帧率 HUD"; AUTO_QUIT="${AUTO_QUIT:-8}" "$BIN"; echo; echo "实验结束。"; }
do_clean() { step "clean" "清理"; rm -rf .build; echo "已清理。"; }
main() { case "${1:-all}" in build) do_build;; observe) do_observe;; clean) do_clean;; all) do_build; do_observe; do_clean;; *) echo "build|observe|clean|all";; esac; }
main "$@"
