// 12 · MPS 矩阵乘法：MPSMatrixMultiplication
// 与 04/05 的手写 GEMM 对照：MPS 的商业级内核在同一数据上的性能与精度。
// MPSMatrix = buffer + 描述符（行/列/步长/类型），内核由 MPS 提供。
import Metal
import MetalPerformanceShaders
import Foundation

func runMpsMatmul() {
    print("=== MPS 12 · MPSMatrixMultiplication ===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let (M, N, K) = (1024, 1024, 1024)
    // 整数倍系数：CPU 验证可精确逐位比对
    let A = (0..<M * K).map { Float(($0 % 13) - 6) * 0.25 }
    let B = (0..<K * N).map { Float(($0 % 11) - 5) * 0.5 }

    func makeMatrix(_ data: [Float], rows: Int, cols: Int) -> MPSMatrix {
        let buf = device.makeBuffer(bytes: data, length: rows * cols * 4)!
        let desc = MPSMatrixDescriptor(rows: rows, columns: cols, rowBytes: cols * 4,
                                       dataType: .float32)
        return MPSMatrix(buffer: buf, descriptor: desc)
    }
    let matA = makeMatrix(A, rows: M, cols: K)
    let matB = makeMatrix(B, rows: K, cols: N)
    let outDesc = MPSMatrixDescriptor(rows: M, columns: N, rowBytes: N * 4, dataType: .float32)
    let matC = MPSMatrix(buffer: device.makeBuffer(length: M * N * 4)!, descriptor: outDesc)

    // 一次描述：M×N 输出，内维 K——MPS 内部自选 tile/内核族
    let gemm = MPSMatrixMultiplication(device: device,
                                       transposeLeft: false, transposeRight: false,
                                       resultRows: M, resultColumns: N, interiorColumns: K, alpha: 1, beta: 0)

    // 预热 + 计时
    for _ in 0..<2 {
        guard let cb = queue.makeCommandBuffer() else { exit(1) }
        gemm.encode(commandBuffer: cb, leftMatrix: matA, rightMatrix: matB, resultMatrix: matC)
        cb.commit(); cb.waitUntilCompleted()
    }
    let t0 = Date()
    guard let cb = queue.makeCommandBuffer() else { exit(1) }
    gemm.encode(commandBuffer: cb, leftMatrix: matA, rightMatrix: matB, resultMatrix: matC)
    cb.commit(); cb.waitUntilCompleted()
    let ms = Date().timeIntervalSince(t0) * 1000

    let c = matC.data.contents().bindMemory(to: Float.self, capacity: M * N)
    var pass = true
    for idx in stride(from: 0, to: M * N, by: M * N / 128) {
        let (r, col) = (idx / N, idx % N)
        var acc: Float = 0
        for k in 0..<K { acc += A[r * K + k] * B[k * N + col] }
        if abs(c[idx] - acc) > 1e-3 * max(1, abs(acc)) { pass = false; print("  ❌ [\(r)][\(col)]"); break }
    }
    let gflops = Double(M) * Double(N) * Double(K) * 2 / (ms / 1000) / 1e9
    print(String(format: "MPS GEMM %dx%dx%d: %.1f ms ≈ %.0f GFLOPS", M, N, K, ms, gflops))
    print("  （对照：05 实验手写 Tiled 512³ ≈ 90 GFLOPS——商业内核与手写内核的差距就是优化空间）")
    print(pass ? "✅ 128 个抽样点与 CPU 一致" : "❌ 验证失败")
}
