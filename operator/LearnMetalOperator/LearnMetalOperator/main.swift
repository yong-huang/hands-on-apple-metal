// main.swift
import Metal
import Foundation

// MARK: - Metal Context
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

// MARK: - Main Function
func main() {
    setenv("APPINTENTS_DISABLE", "1", 1)
    
    print("=== Metal Vector Addition Demo ===")
    print("Starting operator test...\n")
    
    do {
        let context = try MetalContext()
        print("Device: \(context.device.name)\n")
        print("----------------------------------------")
        
        // 运行向量加法
        print("\n=== Running Vector Addition ===")
        try runVectorAdd(context: context)
        
//        // 运行线程索引演示
//        print("\n=== Running Thread Index Demo ===")
//        try runThreadIndex(context: context)
        
        print("\n----------------------------------------")
        print("✅ Operator completed successfully!")
        
    } catch {
        print("❌ Error: \(error.localizedDescription)")
        exit(1)
    }
}

main()
