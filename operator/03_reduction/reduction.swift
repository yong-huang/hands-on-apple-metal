// 03 · 向量点积规约：threadgroup 内存 + 树形归并
// 规约是并行计算的"第一课"：N 个数求和不能简单串行加。
// 两阶段策略：kernel1 组内树形规约（共享内存）→ kernel2 组间收尾。
import Metal
import Foundation

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// 每个线程组规约一段数据：simd 交错 + threadgroup 树形归并
kernel void reduce_sum(device const float* data [[buffer(0)]],
                       device float* partials [[buffer(1)]],
                       uint gid [[thread_position_in_grid]],
                       uint lid [[thread_position_in_threadgroup]],
                       uint lsize [[threads_per_threadgroup]]) {
    // threadgroup 共享内存：同组线程的"黑板"，读写延迟远低于显存
    threadgroup float scratch[256];
    // 交错取数：相邻线程取相邻地址，内存带宽才能打满
    scratch[lid] = data[gid];
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // 树形规约：步长翻倍，活跃线程数减半 → log2(N) 步完成
    for (uint stride = lsize / 2; stride > 0; stride >>= 1) {
        if (lid < stride) { scratch[lid] += scratch[lid + stride]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) { partials[gid / lsize] = scratch[0]; }   // 每组交出一个部分和
}

// 收尾：单组把各组的部分和再规约一次（每组线程先串行吃掉一段）
kernel void reduce_final(device const float* partials [[buffer(0)]],
                         device float* result [[buffer(1)]],
                         constant uint& count [[buffer(2)]],
                         uint lid [[thread_position_in_threadgroup]],
                         uint lsize [[threads_per_threadgroup]]) {
    threadgroup float scratch[256];
    float acc = 0;
    for (uint i = lid; i < count; i += lsize) { acc += partials[i]; }   // 跨步串行累加
    scratch[lid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = lsize / 2; stride > 0; stride >>= 1) {
        if (lid < stride) { scratch[lid] += scratch[lid + stride]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0) { result[0] = scratch[0]; }
}
"""

func runReduction() {
    print("=== Metal 03 · 向量点积规约 ===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let library = try! device.makeLibrary(source: shaderSource, options: nil)
    let reducePSO = try! device.makeComputePipelineState(function: library.makeFunction(name: "reduce_sum")!)
    let finalPSO = try! device.makeComputePipelineState(function: library.makeFunction(name: "reduce_final")!)

    // 点积 = 先逐元素乘（CPU 备料），再 GPU 规约求和
    let n = 1 << 20   // 1M 元素：规约的规模感
    let a = (0..<n).map { Float($0 % 97) * 0.5 - 20.0 }
    let b = (0..<n).map { Float($0 % 89) * 0.25 + 3.0 }
    let products = zip(a, b).map(*)
    let expected = products.reduce(0, +)

    let groupSize = 256
    let groups = n / groupSize
    let dataBuf = device.makeBuffer(bytes: products, length: n * 4)!
    let partialBuf = device.makeBuffer(length: groups * 4)!
    let resultBuf = device.makeBuffer(length: 4)!

    let t0 = Date()
    guard let cb = queue.makeCommandBuffer() else { exit(1) }
    // Pass 1：1M → 4096 个部分和
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(reducePSO)
        enc.setBuffer(dataBuf, offset: 0, index: 0)
        enc.setBuffer(partialBuf, offset: 0, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: groups, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: groupSize, height: 1, depth: 1))
        enc.endEncoding()
    }
    // Pass 2：4096 → 1（256 线程的一组处理不完 4096，串行收尾足够快）
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(finalPSO)
        enc.setBuffer(partialBuf, offset: 0, index: 0)
        enc.setBuffer(resultBuf, offset: 0, index: 1)
        var cnt = UInt32(groups)
        enc.setBytes(&cnt, length: 4, index: 2)
        enc.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
    }
    cb.commit(); cb.waitUntilCompleted()
    let gpuTime = Date().timeIntervalSince(t0)

    let got = resultBuf.contents().bindMemory(to: Float.self, capacity: 1)[0]
    // 验证：浮点求和有顺序误差，用相对误差判定
    let relErr = abs(got - expected) / abs(expected)
    print(String(format: "GPU 规约结果: %.2f（CPU 期望 %.2f，相对误差 %.2e）", got, expected, relErr))
    print(String(format: "两阶段: %d 组 × %d 线程 → %d 部分和 → 1；耗时 %.1f ms", groups, groupSize, groups, gpuTime * 1000))
    print(relErr < 1e-3 ? "✅ 规约验证通过" : "❌ 规约结果偏差过大")
}
