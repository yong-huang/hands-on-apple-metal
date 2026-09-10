import Metal
import Foundation

func runCommandQueue() {
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("Failed to get default Metal device")
        return
    }
    
    // 20260809:
    // 程序输出：
    // === Program 2: Command Queue ===
    // GPU Device: Apple M5 Pro
    // Command Queue created
    // Command Buffer: MyFirstCommandBuffer
    // Command Buffer committed
    // Command Buffer completed

    // GPU 任务执行的核心层次结构：

    // 1. MTLDevice (device) - GPU 硬件抽象层
    // 作用: Metal 与底层 GPU 的接口，代表具体的 GPU 设备（如 "Apple M5 Pro"）
    // 职责:
    // - 提供硬件能力信息（支持的 API、特性等）
    // - 创建其他 Metal 对象的基础设施
    // - 管理渲染管线
    
    // 2. MTLCommandQueue (commandQueue) - 命令队列工厂
    // 作用: 从 Device 创建，用于生成 Command Buffer的"生产流水线"
    // 职责:
    // - makeCommandBuffer() → 获取新的命令缓冲区对象
    // - 内部维护 GPU 任务队列（线程安全）
    // - 每个 Queue 可以并发提交多个 Buffer
    
    // 3. MTLCommandBuffer (commandBuffer) - 实际执行单元
    // 作用: 包含实际要执行的指令集合（绘制调用、计算任务等）
    // 职责:
    // - commit() → 将 Buffer 中的命令发送到 GPU 队列异步执行
    // - waitUntilCompleted() → CPU 端阻塞等待 GPU 完成所有操作

    print("=== Program 2: Command Queue ===")
    print("GPU Device: \(device.name)")
    
    guard let commandQueue = device.makeCommandQueue() else {
        print("Failed to create command queue")
        return
    }
    
    print("Command Queue created")
    
    guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        print("Failed to create command buffer")
        return
    }
    
    commandBuffer.label = "MyFirstCommandBuffer"
    print("Command Buffer: \(commandBuffer.label!)")
    commandBuffer.commit()
    print("Command Buffer committed")
    commandBuffer.waitUntilCompleted()
    print("Command Buffer completed")
    print()
}
