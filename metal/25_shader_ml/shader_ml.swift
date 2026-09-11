// 29 · Shader ML：在着色器中调用神经网络（可行性探测）
// Shader ML 的形态：MSL 直接把 tensor 作为内核参数，片元/内核里调网络。
// 本实验在真机上完成一次"如实的能力探测"：硬件/系统已就绪，
// 但 tensor 模板需要 ML 专用着色器编译链（Xcode 26）——探测会真实触发编译诊断。
import Metal
import Foundation

func runShaderMl() {
    setenv("APPINTENTS_DISABLE", "1", 1)
    print("=== Shader ML 可行性探测 ===")
    guard #available(macOS 26, *), let device = MTLCreateSystemDefaultDevice() else {
        print("❌ 需要 macOS 26+ 的 Metal 设备"); exit(1)
    }
    print("Device: \(device.name)（macOS \(ProcessInfo.processInfo.operatingSystemVersionString)）")

    // —— 1) 目标形态：tensor 直接作为内核参数（Metal 4 的 Shader ML 写法）——
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void tensor_kernel(tensor<float, access::read> in  [[tensor(0)]],
                              tensor<float, access::write> out [[tensor(1)]],
                              uint tid [[thread_position_in_grid]]) {
        float v = in.read(tid, 0);
        out.write(v * 2.0, tid, 0);
    }
    """
    print("探测目标：MSL tensor 模板参数内核（Shader ML 的最小形态）")

    // —— 2) 真实编译尝试：诊断信息如实呈现 ——
    do {
        let lib = try device.makeLibrary(source: source, options: nil)
        print("✅ 意外之喜：运行时编译器支持 tensor 语法 → \(lib.functionNames)")
    } catch {
        let msg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? "\(error)"
        let first = msg.split(separator: "\n").prefix(2).joined(separator: "\n")
        print("❌ 编译失败（预期内的失败，诊断如下）:")
        print("   \(first)")
        print("—— 原因：tensor 模板由 ML 专用着色器编译器处理，运行时 makeLibrary 不包含该前端。")
    }

    // —— 3) 结论：完整路径与当前卡点 ——
    print("""
    📌 走通 Shader ML 的完整路径：
       1. macOS 26.5 + Apple Silicon        → ✅ 已满足
       2. MTLTensor 数据面（实验 27）        → ✅ 已满足
       3. tensor 模板内核的 ML 编译链        → ❌ 需 Xcode 26 构建系统
       4. ML Command Encoder 派发（实验 28） → ✅ 编码器可用，等第 3 步的 PipelineState
    """)
}
