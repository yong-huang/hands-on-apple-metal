// 13 · MPS 逐元素运算：MPSMatrix 加法 + 一元内核族
// 逐元素算子是"带宽受限"的典型（见 06 Roofline）：
// 瓶颈只在搬运字节，计算本身几乎免费。重点看实测带宽逼近上限的程度。
import Metal
import MetalPerformanceShadersGraph
import MetalPerformanceShaders
import Foundation

func runMpsElementwise() {
    print("=== MPS 13 · 矩阵加法与逐元素运算 ===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let (rows, cols) = (2048, 2048)   // 16 MB × 3
    let A = (0..<rows * cols).map { Float($0 % 31) * 0.5 }
    let B = (0..<rows * cols).map { Float($0 % 17) * 0.25 }

    func makeMatrix(_ data: [Float]) -> MPSMatrix {
        let buf = device.makeBuffer(bytes: data, length: rows * cols * 4)!
        let desc = MPSMatrixDescriptor(rows: rows, columns: cols, rowBytes: cols * 4, dataType: .float32)
        return MPSMatrix(buffer: buf, descriptor: desc)
    }
    let matA = makeMatrix(A), matB = makeMatrix(B)
    let matC = MPSMatrix(buffer: device.makeBuffer(length: rows * cols * 4)!,
                         descriptor: MPSMatrixDescriptor(rows: rows, columns: cols, rowBytes: cols * 4, dataType: .float32))

    // —— 加法：MPS 没有公开的"矩阵加法类"（二元算子需子类化 MPSMatrixBinaryKernel），
    // 逐元素运算的工业实践是手写 kernel（或走 MPSGraph，见 11）。本实验手写并测带宽：
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    // float4 向量化：每线程搬运 16 字节 ×3，把带宽打到上限
    kernel void mat_add(device const float4* a [[buffer(0)]],
                        device const float4* b [[buffer(1)]],
                        device float4* c [[buffer(2)]],
                        uint i [[thread_position_in_grid]]) {
        c[i] = a[i] + b[i];
    }
    """
    let library = try! device.makeLibrary(source: source, options: nil)
    let pso = try! device.makeComputePipelineState(function: library.makeFunction(name: "mat_add")!)
    let n4 = rows * cols / 4
    let bufA2 = matA.data
    let bufB2 = matB.data
    let bufC2 = matC.data

    func once() {
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pso)
        enc.setBuffer(bufA2, offset: 0, index: 0)
        enc.setBuffer(bufB2, offset: 0, index: 1)
        enc.setBuffer(bufC2, offset: 0, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: (n4 + 255) / 256, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
    }
    once(); once()   // 预热
    let t0 = Date()
    for _ in 0..<20 { once() }
    let ms = Date().timeIntervalSince(t0) * 1000 / 20

    // 验证：全量抽样 128 点
    let c = bufC2.contents().bindMemory(to: Float.self, capacity: rows * cols)
    var pass = true
    for i in stride(from: 0, to: rows * cols, by: rows * cols / 128) {
        if abs(c[i] - (A[i] + B[i])) > 1e-4 { pass = false; break }
    }
    let bytes = Double(rows * cols * 4 * 3)
    print(String(format: "加法 %dx%d（float4 向量化）: %.2f ms ≈ %.0f GB/s", rows, cols, ms, bytes / (ms / 1000) / 1e9))
    print("  对照 06 实测带宽上限 ~220 GB/s——逐元素算子的性能天花板就是它")
    print(pass ? "✅ 128 点抽样与 CPU 一致" : "❌ 验证失败")
}
