#!/usr/bin/env bash
# 03 · 相机实时滤镜 —— 主演示脚本
# 用法: ./camera_texture.sh [build | observe | clean | all]    （默认 all）
# 相机权限归属 CameraFilter 自己（经 open + LaunchServices 启动），
# 不依赖宿主终端的授权状态；日志写入 .run/ 并实时回显。
set -euo pipefail
cd "$(dirname "$0")"

APP="CameraFilter.app"
BIN="$APP/Contents/MacOS/CameraFilter"
RUNDIR=".run"
LOG="$RUNDIR/app.log"
step() { echo; echo "=====> [$1] $2"; }

log_tail() {   # 跟随日志直到 App 退出
    touch "$LOG"
    local tail_pid
    tail -f "$LOG" & tail_pid=$!
    while pgrep -f "$BIN" > /dev/null 2>&1; do sleep 0.5; done
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
}

do_build() {
    step "build" "swiftc -parse-as-library 编译 + 打包最小 .app（相机权限声明）"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    if ! swiftc -parse-as-library -O camera_texture.swift -o "$BIN" 2> .build.log; then
        cat .build.log; exit 1
    fi
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CameraFilter</string>
  <key>CFBundleIdentifier</key><string>com.handson.metal.camerafilter</string>
  <key>CFBundleExecutable</key><string>CameraFilter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCameraUsageDescription</key><string>Metal 实时滤镜实验需要访问相机</string>
</dict></plist>
PLIST
    codesign --force --sign - "$APP" 2>/dev/null || true
    echo "打包完成 → $APP"
}

# 观察：open + LaunchServices 启动——相机权限归属 CameraFilter 自己
# App 的日志写入 .run/app.log，脚本实时回显；App 窗口按 1-4 切滤镜，12 秒后自动退出
do_observe() {
    step "observe" "运行实验（相机画面实时滤镜；首次运行需允许 CameraFilter 访问相机）"
    mkdir -p "$RUNDIR"; rm -f "$LOG"
    AUTO_QUIT="${AUTO_QUIT:-12}" open -n "$APP" --stdout "$RUNDIR/app.log" --stderr "$RUNDIR/app.log"
    log_tail
    echo
    echo "实验结束。"
}

do_clean() {
    step "clean" "删除 .app、日志与运行目录"
    rm -rf "$APP" .build.log "$RUNDIR"
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
