#!/usr/bin/env bash
# Metal 环境体检：跑本系列实验前的一次性检查
# 用法: scripts/load_resources.sh
set -euo pipefail
cd "$(dirname "$0")/.."
step() { echo; echo "=====> [$1] $2"; }
fail() { echo "❌ $1"; exit 1; }
ok()   { echo "✅ $1"; }

step "check" "硬件与系统"
[ "$(uname -s)" = "Darwin" ] || fail "本系列只能在 macOS 上运行"
uname -m | grep -q arm64 || fail "需要 Apple Silicon（arm64），当前: $(uname -m)"
system_profiler SPHardwareDataType 2>/dev/null | grep "Chip" | sed 's/^ *//' || true
ok "Apple Silicon 就绪"

step "check" "swiftc 编译器（唯一构建依赖，来自 Xcode CLT）"
command -v swiftc >/dev/null || fail "未找到 swiftc，请先执行: xcode-select --install"
swiftc --version | head -1
ok "swiftc 可用（实验脚本用它一行编译，无需 Xcode 工程）"

step "check" "Metal 设备"
T=$(mktemp -d)
cat > "$T/probe.swift" <<'EOF'
import Metal
if let d = MTLCreateSystemDefaultDevice() {
    print("GPU: \(d.name)")
    print("Unified Memory: \(d.hasUnifiedMemory)")
} else {
    print("NO_DEVICE")
}
EOF
swiftc -O "$T/probe.swift" -o "$T/probe" 2>/dev/null
"$T/probe" | grep -q NO_DEVICE && fail "MTLCreateSystemDefaultDevice() 返回 nil，此机器不支持 Metal"
"$T/probe"
rm -rf "$T"
ok "Metal 设备可用，两条实验线都可以跑"

step "done" "环境就绪"
echo "渲染线: cd metal/01_gpu_info && ./gpu_info.sh"
echo "算子线: cd operator/01_vector_add && ./vector_add.sh"
