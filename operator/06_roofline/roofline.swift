// 06 · Roofline 性能测量：算子的"天花板坐标系"
// Roofline 模型：性能(FLOP/s) ≤ min(峰值算力, 带宽 × 算术强度)。
// 本实验实测两个坐标：流式加法（带宽上限）与 GEMM（算力上限），
// 再测不同算术强度的逐元素内核，画出自己机器的 Roofline 数据表。
import Metal
import Foundation

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// 算术强度可调的逐元素内核：每元素做 UNROLL 次乘加（读 4 字节，算 2×UNROLL FLOP）
kernel void stream_kernel(device const float4* a [[buffer(0)]],
                          device const float4* b [[buffer(1)]],
                          device float4* c [[buffer(2)]],
                          constant uint& unroll [[buffer(3)]],
                          uint i [[thread_position_in_grid]]) {
    float4 x = a[i], y = b[i];
    float4 acc = 0;
    for (uint u = 0; u < unroll; u++) {
        acc = acc * 0.5 + x * y;   // 2 FLOP
    }
    c[i] = acc;
}
"""

func bench(queue: MTLCommandQueue, pso: MTLComputePipelineState, device: MTLDevice,
           n4: Int, unroll: UInt32, iters: Int) -> (ms: Double, ai: Double, gflops: Double, bw: Double) {
    let a = device.makeBuffer(length: n4 * 16)!
    let b = device.makeBuffer(length: n4 * 16)!
    let c = device.makeBuffer(length: n4 * 16)!
    // 预热
    for _ in 0..<2 { _ = once(queue, pso, a, b, c, n4, unroll) }
    var u = unroll
    let t0 = Date()
    for _ in 0..<iters { _ = once(queue, pso, a, b, c, n4, unroll) }
    let ms = Date().timeIntervalSince(t0) * 1000 / Double(iters)
    _ = u; u = 0
    let bytes = Double(n4) * 16 * 3                     // 读 a、b + 写 c
    let flops = Double(n4) * 4 * Double(unroll) * 2     // float4 × unroll × 2 FLOP
    let ai = flops / bytes                               // 算术强度 FLOP/Byte
    return (ms, ai, flops / (ms / 1000) / 1e9, bytes / (ms / 1000) / 1e9)
}

func once(_ queue: MTLCommandQueue, _ pso: MTLComputePipelineState,
          _ a: MTLBuffer, _ b: MTLBuffer, _ c: MTLBuffer, _ n4: Int, _ unroll: UInt32) {
    guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
    var u = unroll
    enc.setComputePipelineState(pso)
    enc.setBuffer(a, offset: 0, index: 0)
    enc.setBuffer(b, offset: 0, index: 1)
    enc.setBuffer(c, offset: 0, index: 2)
    enc.setBytes(&u, length: 4, index: 3)
    enc.dispatchThreadgroups(MTLSize(width: (n4 + 255) / 256, height: 1, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
}

func runRoofline() {
    print("=== Metal 06 · Roofline 性能测量 ===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")
    let library = try! device.makeLibrary(source: shaderSource, options: nil)
    let pso = try! device.makeComputePipelineState(function: library.makeFunction(name: "stream_kernel")!)

    let n4 = 1 << 22   // 4M 个 float4 = 64 MB 数据（超过各级缓存，测的是真显存带宽）
    print(String(format: "数据规模: %.0f MB ×3（读A/读B/写C）\n", Double(n4) * 16 / 1e6))
    print("unroll   强度(FLOP/B)  带宽(GB/s)   算力(GFLOPS)")

    var peakBW = 0.0, peakFlops = 0.0
    for unroll: UInt32 in [1, 2, 4, 8, 16, 32, 64] {
        let r = bench(queue: queue, pso: pso, device: device, n4: n4, unroll: unroll, iters: 5)
        peakBW = max(peakBW, r.bw); peakFlops = max(peakFlops, r.gflops)
        print(String(format: "%-8d %-12.1f %-12.1f %-12.1f", unroll, r.ai, r.bw, r.gflops))
    }
    print(String(format: "\n📈 本机 Roofline 坐标（实测）:"))
    print(String(format: "  带宽上限（屋脊左侧平台）: ≥ %.0f GB/s", peakBW))
    print(String(format: "  算力上限（屋脊右侧平台）: ≥ %.0f GFLOPS（FP32，本内核）", peakFlops))
    print(String(format: "  拐点（脊点）算术强度 ≈ %.0f FLOP/B —— 算子强度低于它的吃带宽，高于它的吃算力", peakFlops / peakBW))
    print("✅ 用你算子的算术强度对号入座，就知道该优化访存还是该优化计算")
}
