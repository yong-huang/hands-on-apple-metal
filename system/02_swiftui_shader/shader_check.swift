// 02 自检（独立 headless 进程）：验证 shader 编译产物与数学在 GPU 上真实生效
// ① 运行时编译 duotone 数学并跑 GPU ② 加载 CLI 编译的 default.metallib 派发自检内核
import Metal
import Foundation

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

let duotoneSrc = """
#include <metal_stdlib>
using namespace metal;
half4 duotone(half4 color, float amount) {
    float l = dot(color.rgb, half3(0.299, 0.587, 0.114));
    half3 cool = half3(0.10, 0.35, 0.65);
    half3 warm = half3(1.00, 0.60, 0.25);
    half3 toned = mix(cool, warm, half(clamp(l, 0.0, 1.0)));
    return half4(mix(color.rgb, toned, half(amount)), color.a);
}
kernel void duotone_check(device const float4* in [[buffer(0)]],
                          device float4* out [[buffer(1)]],
                          constant float& amt [[buffer(2)]],
                          uint i [[thread_position_in_grid]]) {
    out[i] = float4(duotone(half4(in[i]), amt));
}
"""

// CLI 编译的 Effects.metal 产物里内置的自检内核（与 SwiftUI 调用同一 metallib）
let cliWrapSrc = """
#include <metal_stdlib>
using namespace metal;
kernel void duotone_selfcheck(device const float4* in [[buffer(0)]],
                              device float4* out [[buffer(1)]],
                              constant float& amt [[buffer(2)]],
                              uint i [[thread_position_in_grid]]) {
    out[i] = float4(duotone(half4(in[i]), amt));
}
half4 duotone(half4 color, float amount) {
    float l = dot(color.rgb, half3(0.299, 0.587, 0.114));
    half3 cool = half3(0.10, 0.35, 0.65);
    half3 warm = half3(1.00, 0.60, 0.25);
    half3 toned = mix(cool, warm, half(clamp(l, 0.0, 1.0)));
    return half4(mix(color.rgb, toned, half(amount)), color.a);
}
"""

func gpuRun(_ device: MTLDevice, _ pso: MTLComputePipelineState, input: [SIMD4<Float>], amount: Float) -> [SIMD4<Float>] {
    let n = input.count
    let inB = device.makeBuffer(bytes: input, length: n * 16)!
    let outB = device.makeBuffer(length: n * 16)!
    var a = amount
    guard let cb = device.makeCommandQueue()!.makeCommandBuffer(),
          let enc = cb.makeComputeCommandEncoder() else { return [] }
    enc.setComputePipelineState(pso)
    enc.setBuffer(inB, offset: 0, index: 0)
    enc.setBuffer(outB, offset: 0, index: 1)
    enc.setBytes(&a, length: 4, index: 2)
    enc.dispatchThreadgroups(MTLSize(width: (n + 255) / 256, height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    let p = outB.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
    var result = [SIMD4<Float>](repeating: .zero, count: n)
    for i in 0..<n { result[i] = p[i] }          // 朴素下标拷贝（withMemoryRebound 重释 Array 在此会崩）
    return result
}

let dev = MTLCreateSystemDefaultDevice()!
let n = 64 * 64
var input = [SIMD4<Float>](repeating: .zero, count: n)
for i in 0..<n {
    let u = Float(i % 64) / 63, v = Float(i / 64) / 63
    input[i] = SIMD4(0.2 + 0.6 * u, 0.3 + 0.4 * v, 0.7 - 0.5 * u, 1)
}

// ① 运行时编译 duotone 数学 → GPU 跑 0/1 两档 → 断言像素变化
let lib1 = try! dev.makeLibrary(source: duotoneSrc, options: nil)
err("step2 管线"); let pso1 = try! dev.makeComputePipelineState(function: lib1.makeFunction(name: "duotone_check")!)
err("step3 GPU run"); let base = gpuRun(dev, pso1, input: input, amount: 0)
let toned = gpuRun(dev, pso1, input: input, amount: 1)
var diff = 0
for i in 0..<n where abs(base[i].x - toned[i].x) > 0.02 { diff += 1 }
err(String(format: "自检①：GPU duotone 数学——%.1f%% 像素被改变", Double(diff) / Double(n) * 100))
print(diff > n / 2 ? "✅ 自检①通过：shader 数学真实生效" : "❌ 自检①失败")

// ② 加载 CLI 编译的 default.metallib（SwiftUI 实际查找的同一文件），派发其自检内核
let cwd = FileManager.default.currentDirectoryPath
let exeDir = CommandLine.arguments.first.flatMap {
    URL(fileURLWithPath: $0).deletingLastPathComponent().path
}
let candidates = [cwd + "/.build/default.metallib", exeDir.map { $0 + "/default.metallib" }!]
guard let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }),
      let lib2 = try? dev.makeLibrary(URL: URL(fileURLWithPath: path)) else {
    print("❌ 自检②失败：找不到 default.metallib（候选：\(candidates)）"); exit(1)
}
guard let fn2 = lib2.makeFunction(name: "duotone_selfcheck"),
      let pso2 = try? dev.makeComputePipelineState(function: fn2) else {
    err("❌ 自检②失败：duotone_selfcheck 函数/管线创建失败"); exit(1)
}
let wrapOut = gpuRun(dev, pso2, input: input, amount: 1)
var wrapDiff = 0
for i in 0..<n where abs(wrapOut[i].x - input[i].x) > 0.05 { wrapDiff += 1 }
print(String(format: "自检②：CLI 编译的 metallib 在 GPU 上派发执行——%.1f%% 像素被 duotone 改变", Double(wrapDiff) / Double(n) * 100))
print(wrapDiff > n / 2 ? "✅ 自检②通过：CLI 编译产物真实可用" : "❌ 自检②失败")
