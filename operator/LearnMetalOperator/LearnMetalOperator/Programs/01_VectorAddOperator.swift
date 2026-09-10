// Operators/VectorAdd/VectorAddOperator.swift
import Metal
import Foundation

// Vector Addition Operator
class VectorAddOperator {
    private let context: MetalContext
    private let pipelineState: MTLComputePipelineState
    private let count: Int
    
    // Metal 着色器源码（内嵌在算子文件中）
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    
    kernel void add_arrays(
        device const float* inA [[buffer(0)]],
        device const float* inB [[buffer(1)]],
        device float* out [[buffer(2)]],
        uint index [[thread_position_in_grid]]
    ) {
        out[index] = inA[index] + inB[index];
    }
    """
    
    init(context: MetalContext, count: Int = 1024) throws {
        self.context = context
        self.count = count
        
        // 从源码编译着色器
        let library = try context.device.makeLibrary(source: VectorAddOperator.shaderSource, options: nil)
        
        guard let function = library.makeFunction(name: "add_arrays") else {
            throw NSError(domain: "ShaderError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create shader function"])
        }
        
        self.pipelineState = try context.device.makeComputePipelineState(function: function)
    }
    
    func run() throws {
        print("  Size: \(count) elements")
        
        let bufferSize = count * MemoryLayout<Float>.size
        
        // 生成测试数据
        let arrayA = (0..<count).map { Float($0) }
        let arrayB = (0..<count).map { Float($0) * 2.0 }
        
        // 创建 Metal 缓冲区
        guard let bufferA = context.device.makeBuffer(bytes: arrayA, length: bufferSize, options: .storageModeShared),
              let bufferB = context.device.makeBuffer(bytes: arrayB, length: bufferSize, options: .storageModeShared),
              let bufferOut = context.device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            throw NSError(domain: "BufferError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create buffers"])
        }
        
        // 创建命令缓冲
        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw NSError(domain: "CommandError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        // 创建计算编码器
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw NSError(domain: "CommandError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create compute encoder"])
        }
        
        // 设置管道和缓冲区
        encoder.setComputePipelineState(pipelineState)
        encoder.setBuffer(bufferA, offset: 0, index: 0)
        encoder.setBuffer(bufferB, offset: 0, index: 1)
        encoder.setBuffer(bufferOut, offset: 0, index: 2)
        
        // 配置线程组
        let threadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
        let numGroups = MTLSize(
            width: (count + threadsPerGroup.width - 1) / threadsPerGroup.width,
            height: 1,
            depth: 1
        )
        
        // 调度计算
        encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        
        // 提交并等待完成
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // 读取结果 - 修正了这里
        let outPointer = bufferOut.contents().bindMemory(to: Float.self, capacity: count)
        let results = Array(UnsafeBufferPointer(start: outPointer, count: count))
        
        // 验证结果
        var allMatch = true
        for i in 0..<count {
            let expected = arrayA[i] + arrayB[i]
            if abs(results[i] - expected) > 0.001 {
                print("  ❌ Mismatch at index \(i): expected \(expected), got \(results[i])")
                allMatch = false
                break
            }
        }
        
        if allMatch {
            print("  ✅ All \(count) results match! Vector addition successful.")
        } else {
            print("  ❌ Verification failed")
        }
    }
}

// 全局函数用于主入口调用
func runVectorAdd(context: MetalContext) throws {
    let operatorInstance = try VectorAddOperator(context: context)
    try operatorInstance.run()
}
