#!/usr/bin/env bash
# 05 · Vision 人脸检测 → Metal 马赛克 —— 主演示脚本
# 用法: ./vision_face.sh [build | observe | clean | all]    （默认 all）
# 相机权限：最小 .app 包携带 NSCameraUsageDescription，首次运行弹窗授权
set -euo pipefail
cd "$(dirname "$0")"

APP="VisionFace.app"
BIN="$APP/Contents/MacOS/VisionFace"
step() { echo; echo "=====> [$1] $2"; }

log_tail() {
    touch .run/app.log
    local tail_pid
    tail -f .run/app.log & tail_pid=$!
    while pgrep -f "$BIN" > /dev/null 2>&1; do sleep 0.5; done
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
}

do_build() {
    step "build" "swiftc 编译 + 打包最小 .app（相机权限声明）"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/.run"
    if ! swiftc -parse-as-library -O vision_face.swift -o "$BIN" 2> .build.log; then
        cat .build.log; exit 1
    fi
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VisionFace</string>
  <key>CFBundleIdentifier</key><string>com.handson.metal.visionface</string>
  <key>CFBundleExecutable</key><string>VisionFace</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCameraUsageDescription</key><string>Vision 人脸马赛克实验需要访问相机</string>
</dict></plist>
PLIST
    codesign --force --sign - "$APP" 2>/dev/null || true
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>VisionFace</string>
  <key>CFBundleIdentifier</key><string>com.handson.metal.visionface</string>
  <key>CFBundleExecutable</key><string>VisionFace</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSCameraUsageDescription</key><string>Vision 人脸马赛克实验需要访问相机</string>
</dict></plist>
PLIST
    codesign --force --sign - "$APP" 2>/dev/null || true
    echo "打包完成 → $APP"
}

do_observe() {
    step "observe" "运行实验（对准你的脸，检出即打马赛克；首次运行需允许相机）"
    # open + LaunchServices 启动——相机权限归属 CameraFilter 自己，不依赖宿主终端
    mkdir -p .run; rm -f .run/app.log
    AUTO_QUIT="${AUTO_QUIT:-15}" open -n "$APP" --stdout "$PWD/.run/app.log" --stderr "$PWD/.run/app.log"
    log_tail
    echo
    echo "实验结束。"
    echo
    echo "实验结束。"
}

do_clean() {
    step "clean" "删除 .app、日志与运行目录"
    rm -rf "$APP" .build.log .run
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
