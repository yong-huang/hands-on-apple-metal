import Metal
import Foundation

// MARK: - Metal 上下文（算子实验的公共底座）
// 每个算子实验都从这两个对象出发：device 负责"创建一切"，commandQueue 负责"提交一切"。
class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "MetalError", code: -1, userInfo: [NSLocalizedDescriptionKey: "Metal is not supported on this system"])
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw NSError(domain: "MetalError", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create command queue"])
        }
        self.commandQueue = commandQueue
    }
}

// MARK: - 入口包装：调用实验程序本体 vector_add.swift 中的 runVectorAdd(context:)
// 程序在 CPU 端验证完结果后自然退出，无需窗口。
func main() {
    setenv("APPINTENTS_DISABLE", "1", 1)   // 静音与本实验无关的系统级告警

    print("=== Metal Vector Addition Demo ===")
    do {
        let context = try MetalContext()
        print("Device: \(context.device.name)\n")
        try runVectorAdd(context: context)
        print("\n✅ Operator completed successfully!")
    } catch {
        print("❌ Error: \(error.localizedDescription)")
        exit(1)
    }
}

main()
