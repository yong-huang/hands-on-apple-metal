// 04 · 矩阵乘法 Naive：每线程算一个输出元素
// 基线版 GEMM：直观看懂"线程如何映射到矩阵元素"，为 05 的 Tiled 优化做铺垫。
import Metal
import Foundation

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// 每线程计算 C[row][col] 的一个元素：沿 K 轴串行点乘
kernel void matmul_naive(device const float* A [[buffer(0)]],   // M×K
                         device const float* B [[buffer(1)]],   // K×N
                         device float* C [[buffer(2)]],         // M×N
                         constant uint3& dims [[buffer(3)]],    // M, N, K
                         uint2 gid [[thread_position_in_grid]]) {
    uint row = gid.y, col = gid.x;
    if (row >= dims.x || col >= dims.y) { return; }
    float acc = 0;
    for (uint k = 0; k < dims.z; k++) {
        acc += A[row * dims.z + k] * B[k * dims.y + col];
    }
    C[row * dims.y + col] = acc;
}
"""

func runMatmulNaive() {
    print("=== Metal 04 · 矩阵乘法 Naive ===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let library = try! device.makeLibrary(source: shaderSource, options: nil)
    let pso = try! device.makeComputePipelineState(function: library.makeFunction(name: "matmul_naive")!)
    print("每线程组最大线程数（内核）: \(pso.maxTotalThreadsPerThreadgroup)")

    let (M, N, K) = (256, 256, 256)
    // 有理数初始化，保证 CPU/GPU 结果逐元素可精确比对
    let A = (0..<M * K).map { Float(($0 % 13) - 6) * 0.25 }
    let B = (0..<K * N).map { Float(($0 % 11) - 5) * 0.5 }

    let bufA = device.makeBuffer(bytes: A, length: M * K * 4)!
    let bufB = device.makeBuffer(bytes: B, length: K * N * 4)!
    let bufC = device.makeBuffer(length: M * N * 4)!
    var dims = SIMD3<UInt32>(UInt32(M), UInt32(N), UInt32(K))

    guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { exit(1) }
    enc.setComputePipelineState(pso)
    enc.setBuffer(bufA, offset: 0, index: 0)
    enc.setBuffer(bufB, offset: 0, index: 1)
    enc.setBuffer(bufC, offset: 0, index: 2)
    enc.setBytes(&dims, length: 12, index: 3)
    // 2D 网格：x 方向 N 列、y 方向 M 行，各 16×16 线程组
    enc.dispatchThreadgroups(MTLSize(width: (N + 15) / 16, height: (M + 15) / 16, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    enc.endEncoding()
    let t0 = Date()
    cb.commit(); cb.waitUntilCompleted()
    let gpuMs = Date().timeIntervalSince(t0) * 1000

    // CPU 验证（抽样全量中的 128 个点，逐位一致才通过——整数倍系数保证无舍入差）
    let c = bufC.contents().bindMemory(to: Float.self, capacity: M * N)
    var pass = true
    for idx in stride(from: 0, to: M * N, by: M * N / 128) {
        let (r, col) = (idx / N, idx % N)
        var acc: Float = 0
        for k in 0..<K { acc += A[r * K + k] * B[k * N + col] }
        if c[idx] != acc { pass = false; print("  ❌ [\(r)][\(col)] gpu=\(c[idx]) cpu=\(acc)"); break }
    }
    let gflops = Double(M) * Double(N) * Double(K) * 2 / (gpuMs / 1000) / 1e9
    print(String(format: "Naive GEMM %dx%dx%d: %.1f ms ≈ %.1f GFLOPS", M, N, K, gpuMs, gflops))
    print(pass ? "✅ 128 个抽样点与 CPU 逐位一致" : "❌ 验证失败")
}
