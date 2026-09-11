// 05 · 矩阵乘法 Tiled：threadgroup 分块 + 数据复用
// Naive 版每个输出元素要把 A 的一行、B 的一列完整读一遍——显存带宽被重复流量打爆。
// Tiled 版把 A、B 分块搬进 threadgroup 内存，块内每个线程复用同一份tile，
// 对 A、B 的全局访存量下降 TILE 倍——这就是大模型 GEMM 优化的原点。
import Metal
import Foundation

let TILE = 16

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
#define TILE 16

kernel void matmul_tiled(device const float* A [[buffer(0)]],
                         device const float* B [[buffer(1)]],
                         device float* C [[buffer(2)]],
                         constant uint3& dims [[buffer(3)]],   // M, N, K
                         uint2 gid [[thread_position_in_grid]],
                         uint2 lid [[thread_position_in_threadgroup]]) {
    threadgroup float tileA[TILE][TILE];
    threadgroup float tileB[TILE][TILE];

    uint row = gid.y, col = gid.x;
    float acc = 0;

    // 沿 K 轴一块一块推进：先把两块tile搬进共享内存，再用完
    for (uint t = 0; t < dims.z; t += TILE) {
        // 协作搬运：每线程搬一个元素（16×16 = 256 个搬运工）
        uint aCol = t + lid.x;
        tileA[lid.y][lid.x] = (row < dims.x && aCol < dims.z) ? A[row * dims.z + aCol] : 0.0;
        uint bRow = t + lid.y;
        tileB[lid.y][lid.x] = (bRow < dims.z && col < dims.y) ? B[bRow * dims.y + col] : 0.0;
        // 屏障：必须等整块tile就位才能开始算
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint k = 0; k < TILE; k++) {
            acc += tileA[lid.y][k] * tileB[k][lid.x];
        }
        // 屏障：算完之前不能有人搬下一块（覆盖共享内存）
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (row < dims.x && col < dims.y) {
        C[row * dims.y + col] = acc;
    }
}
"""

func runMatmulTiled() {
    print("=== Metal 05 · 矩阵乘法 Tiled（vs Naive）===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let library = try! device.makeLibrary(source: shaderSource, options: nil)
    let pso = try! device.makeComputePipelineState(function: library.makeFunction(name: "matmul_tiled")!)

    let (M, N, K) = (512, 512, 512)
    let A = (0..<M * K).map { Float(($0 % 13) - 6) * 0.25 }
    let B = (0..<K * N).map { Float(($0 % 11) - 5) * 0.5 }
    let bufA = device.makeBuffer(bytes: A, length: M * K * 4)!
    let bufB = device.makeBuffer(bytes: B, length: K * N * 4)!
    let bufC = device.makeBuffer(length: M * N * 4)!
    var dims = SIMD3<UInt32>(UInt32(M), UInt32(N), UInt32(K))

    func gpuGemm() -> (ms: Double, c: UnsafeMutablePointer<Float>) {
        let bufC = device.makeBuffer(length: M * N * 4)!
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { fatalError() }
        enc.setComputePipelineState(pso)
        enc.setBuffer(bufA, offset: 0, index: 0)
        enc.setBuffer(bufB, offset: 0, index: 1)
        enc.setBuffer(bufC, offset: 0, index: 2)
        enc.setBytes(&dims, length: 12, index: 3)
        enc.dispatchThreadgroups(MTLSize(width: (N + TILE - 1) / TILE, height: (M + TILE - 1) / TILE, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: TILE, height: TILE, depth: 1))
        enc.endEncoding()
        let t0 = Date()
        cb.commit(); cb.waitUntilCompleted()
        return (Date().timeIntervalSince(t0) * 1000, bufC.contents().bindMemory(to: Float.self, capacity: M * N))
    }

    let (ms, c) = gpuGemm()
    // 验证 + 性能
    var pass = true
    for idx in stride(from: 0, to: M * N, by: M * N / 128) {
        let (r, col) = (idx / N, idx % N)
        var acc: Float = 0
        for k in 0..<K { acc += A[r * K + k] * B[k * N + col] }
        if abs(c[idx] - acc) > 1e-3 * max(1, abs(acc)) { pass = false; print("  ❌ [\(r)][\(col)]"); break }
    }
    let gflops = Double(M) * Double(N) * Double(K) * 2 / (ms / 1000) / 1e9
    print(String(format: "Tiled GEMM %dx%dx%d（tile=%d）: %.1f ms ≈ %.1f GFLOPS", M, N, K, TILE, ms, gflops))
    print("访存量分析: Naive 每输出元素读 K×2 次；Tiled 复用后全局读量 ÷\(TILE)")
    print(pass ? "✅ 128 个抽样点与 CPU 一致" : "❌ 验证失败")
}
