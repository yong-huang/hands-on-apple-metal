// Operators/ThreadIndex/ThreadIndexOperator.swift
import Metal
import Foundation

// Thread Index Demo Operator
class ThreadIndexOperator {
    private let context: MetalContext
    private let pipelineState: MTLComputePipelineState
    private let totalThreads: Int
    
    // Metal 着色器源码
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    
    struct ThreadInfo {
        uint thread_position_in_grid;
        uint threadgroup_position_in_grid;
        uint thread_position_in_threadgroup;
        uint threadgroup_size;
    };
    
    kernel void print_thread_info(
        device ThreadInfo* output [[buffer(0)]],
        uint thread_position_in_grid [[thread_position_in_grid]],
        uint threadgroup_position_in_grid [[threadgroup_position_in_grid]],
        uint thread_position_in_threadgroup [[thread_position_in_threadgroup]],
        uint threadgroup_size [[threads_per_threadgroup]]
    ) {
        uint index = thread_position_in_grid;
        output[index].thread_position_in_grid = thread_position_in_grid;
        output[index].threadgroup_position_in_grid = threadgroup_position_in_grid;
        output[index].thread_position_in_threadgroup = thread_position_in_threadgroup;
        output[index].threadgroup_size = threadgroup_size;
    }
    """
    
    init(context: MetalContext, totalThreads: Int = 256) throws {
        self.context = context
        self.totalThreads = totalThreads
        
        // 从源码编译着色器
        let library = try context.device.makeLibrary(source: ThreadIndexOperator.shaderSource, options: nil)
        
        guard let function = library.makeFunction(name: "print_thread_info") else {
            throw NSError(domain: "ShaderError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create shader function"])
        }
        
        self.pipelineState = try context.device.makeComputePipelineState(function: function)
    }
    
    func run() throws {
        print("  Total Threads: \(totalThreads)")
        print("  Threads Per Group: 64")
        print("  Number of Groups: \(totalThreads / 64)\n")
        
        // 定义线程信息结构体（与 Metal 端对应）
        struct ThreadInfo {
            var thread_position_in_grid: UInt32
            var threadgroup_position_in_grid: UInt32
            var thread_position_in_threadgroup: UInt32
            var threadgroup_size: UInt32
        }
        
        let bufferSize = totalThreads * MemoryLayout<ThreadInfo>.size
        
        // 创建输出缓冲区
        guard let bufferOut = context.device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            throw NSError(domain: "BufferError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create buffer"])
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
        encoder.setBuffer(bufferOut, offset: 0, index: 0)
        
        // 配置线程组
        let threadsPerGroup = MTLSize(width: 64, height: 1, depth: 1)
        let numGroups = MTLSize(
            width: totalThreads / threadsPerGroup.width,
            height: 1,
            depth: 1
        )
        
        // 调度计算
        encoder.dispatchThreadgroups(numGroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        
        // 提交并等待完成
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // 读取结果
        let outPointer = bufferOut.contents().bindMemory(to: ThreadInfo.self, capacity: totalThreads)
        let results = Array(UnsafeBufferPointer(start: outPointer, count: totalThreads))
        
        // 打印每个线程的信息
        print("📊 Thread Index Information:")
        print("┌───────┬─────────────────────┬──────────────────────┬────────────────────────┬─────────────────┐")
        print("│ Index │ thread_position     │ threadgroup_position │ thread_position_in_tg │ threadgroup_size │")
        print("│       │ in_grid             │ in_grid              │                        │                 │")
        print("├───────┼─────────────────────┼──────────────────────┼────────────────────────┼─────────────────┤")
        
        for i in 0..<totalThreads {
            let info = results[i]
            let localIndex = i % 64
            
            print(String(format: "│ %5d │ %19d │ %20d │ %22d │ %15d │",
                         i,
                         info.thread_position_in_grid,
                         info.threadgroup_position_in_grid,
                         info.thread_position_in_threadgroup,
                         info.threadgroup_size))
            
            // 在每个线程组结束后打印分隔线
            if localIndex == 63 && i < totalThreads - 1 {
                print("├───────┼─────────────────────┼──────────────────────┼────────────────────────┼─────────────────┤")
            }
        }
        
        print("└───────┴─────────────────────┴──────────────────────┴────────────────────────┴─────────────────┘")
        
        // 验证
        var allValid = true
        for i in 0..<totalThreads {
            let info = results[i]
            let expectedGroupIndex = UInt32(i / 64)
            let expectedLocalIndex = UInt32(i % 64)
            
            if info.thread_position_in_grid != UInt32(i) {
                print("  ❌ Thread \(i): thread_position_in_grid = \(info.thread_position_in_grid), expected \(i)")
                allValid = false
            }
            if info.threadgroup_position_in_grid != expectedGroupIndex {
                print("  ❌ Thread \(i): threadgroup_position_in_grid = \(info.threadgroup_position_in_grid), expected \(expectedGroupIndex)")
                allValid = false
            }
            if info.thread_position_in_threadgroup != expectedLocalIndex {
                print("  ❌ Thread \(i): thread_position_in_threadgroup = \(info.thread_position_in_threadgroup), expected \(expectedLocalIndex)")
                allValid = false
            }
            if info.threadgroup_size != 64 {
                print("  ❌ Thread \(i): threadgroup_size = \(info.threadgroup_size), expected 64")
                allValid = false
            }
        }
        
        if allValid {
            print("\n  ✅ All thread indices are correct!")
        } else {
            print("\n  ❌ Some thread indices are incorrect")
        }
    }
}

// 全局函数用于主入口调用
func runThreadIndex(context: MetalContext) throws {
    let operatorInstance = try ThreadIndexOperator(context: context, totalThreads: 256)
    try operatorInstance.run()
}
