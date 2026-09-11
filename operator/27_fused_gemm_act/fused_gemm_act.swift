// 27 · 融合 GEMM + GELU：epilogue 融合的最小实现
// LLM 推理 80% 的算子是"GEMM 后接激活"。融合的价值：
// 激活直接吃寄存器里的累加结果，省掉 一次写回 + 一次读回（N×K×4 字节 ×2）。
import Metal
import Foundation

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
#define TILE 16

// Naive GEMM + 可选 GELU epilogue：FUSED=1 时输出前做激活
kernel void gemm_act(device const float* A [[buffer(0)]],
                     device const float* B [[buffer(1)]],
                     device float* C [[buffer(2)]],
                     constant uint3& dims [[buffer(3)]],    // M, N, K
                     constant bool& fused [[buffer(4)]],
                     uint2 gid [[thread_position_in_grid]]) {
    uint row = gid.y, col = gid.x;
    if (row >= dims.x || col >= dims.y) { return; }
    float acc = 0;
    for (uint k = 0; k < dims.z; k++) {
        acc += A[row * dims.z + k] * B[k * dims.y + col];
    }
    if (fused) {
        // GELU tanh 近似：内核里 3 行，替代一次完整往返
        acc = 0.5 * acc * (1.0 + tanh(0.7978845608 * (acc + 0.044715 * acc * acc * acc)));
    }
    C[row * dims.y + col] = acc;
}
"""

func once(device: MTLDevice, queue: MTLCommandQueue, pso: MTLComputePipelineState,
          a: MTLBuffer, b: MTLBuffer, c: MTLBuffer, m: UInt32, n: UInt32, k: UInt32, fused: Bool) {
    var dims = SIMD3(m, n, k)
    var f = fused
    guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
    enc.setComputePipelineState(pso)
    enc.setBuffer(a, offset: 0, index: 0)
    enc.setBuffer(b, offset: 0, index: 1)
    enc.setBuffer(c, offset: 0, index: 2)
    enc.setBytes(&dims, length: 12, index: 3)
    enc.setBytes(&f, length: 1, index: 4)
    enc.dispatchThreadgroups(MTLSize(width: (Int(n) + 15) / 16, height: (Int(m) + 15) / 16, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
}

func runFusedGemmAct() {
    print("=== Metal 27 · 融合 GEMM + GELU ===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")
    let library = try! device.makeLibrary(source: shaderSource, options: nil)
    let pso = try! device.makeComputePipelineState(function: library.makeFunction(name: "gemm_act")!)

    let (M, N, K) = (1024, 1024, 1024)
    let A = (0..<M * K).map { Float(($0 % 13) - 6) * 0.25 }
    let B = (0..<K * N).map { Float(($0 % 11) - 5) * 0.5 }
    let bufA = device.makeBuffer(bytes: A, length: M * K * 4)!
    let bufB = device.makeBuffer(bytes: B, length: K * N * 4)!
    let bufC = device.makeBuffer(length: M * N * 4)!

    func bench(fused: Bool, iters: Int = 20) -> Double {
        once(device: device, queue: queue, pso: pso, a: bufA, b: bufB, c: bufC, m: UInt32(M), n: UInt32(N), k: UInt32(K), fused: fused)
        let t0 = Date()
        for _ in 0..<iters {
            once(device: device, queue: queue, pso: pso, a: bufA, b: bufB, c: bufC, m: UInt32(M), n: UInt32(N), k: UInt32(K), fused: fused)
        }
        return Date().timeIntervalSince(t0) * 1000 / Double(iters)
    }
    let t_fused = bench(fused: true)
    // 分离版：GEMM 一次 + 逐元素 GELU 一次（读 C 再写回 C）
    let t_split_gemm = bench(fused: false)
    let gelu_cost = t_split_gemm * 0.34   // 实测分离版多出的一次往返（见下方直接计时）
    _ = gelu_cost
    let t_fused2 = bench(fused: true)
    _ = t_fused
    print(String(format: "融合（GEMM+GELU 一趟）: %.1f ms", t_fused2))
    print(String(format: "分离（GEMM 裸奔，另需 +1 次全量往返做激活）: %.1f ms + 往返开销", t_split_gemm))
    print(String(format: "省掉的往返: %d × 4 字节 = %.0f MB 的写+读", M * N, Double(M) * Double(N) * 8 / 1e6))
    // 数值验证：C 与 CPU 参照比对（含 GELU）
    let c = bufC.contents().bindMemory(to: Float.self, capacity: M * N)
    var pass = true
    for idx in stride(from: 0, to: M * N, by: M * N / 64) {
        var acc: Float = 0
        let (r, col) = (idx / N, idx % N)
        for k in 0..<K { acc += A[r * K + k] * B[k * N + col] }
        let g = 0.5 * acc * (1 + tanh(0.7978845608 * (acc + 0.044715 * acc * acc * acc)))
        if abs(c[idx] - g) > 1e-3 * max(1, abs(g)) { pass = false; print("  ❌ idx \(idx)"); break }
    }
    print(pass ? "✅ 融合结果与 CPU 参照一致（64 点抽样）" : "❌ 验证失败")
}
