// 23 · 帧捕获与 GPU 调试：MTLCaptureManager 程序化捕获
// 不开窗口也能"看清"GPU 在干什么：把命令队列的工作捕获成 .gputrace，
// 双击用 Xcode 打开即可逐条查看编码的命令、kernel 执行耗时、缓冲内容。
// 程序化捕获（MTLCaptureDescriptor）是自动回归/GPU 性能存档的标准姿势。
import Metal
import Foundation

class GpuCaptureDemo {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    var pipelineState: MTLComputePipelineState!

    // 一个简单的 kernel：数组翻倍（捕获后能在 Xcode 里看到它执行 3 次）
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void double_array(
        device const float* in [[buffer(0)]],
        device float* out [[buffer(1)]],
        uint i [[thread_position_in_grid]])
    {
        out[i] = in[i] * 2.0;
    }
    """

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "MetalError", code: -1)
        }
        self.device = device
        commandQueue = device.makeCommandQueue()!
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        pipelineState = try device.makeComputePipelineState(
            function: library.makeFunction(name: "double_array")!)
    }

    // 编码一次"翻倍"计算
    func encodePass(input: MTLBuffer, output: MTLBuffer, count: Int) {
        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipelineState)
        enc.setBuffer(input, offset: 0, index: 0)
        enc.setBuffer(output, offset: 0, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: (count + 63) / 64, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
}

func runGpuCapture() {
    setenv("APPINTENTS_DISABLE", "1", 1)
    print("=== Metal 23 · MTLCaptureManager 程序化帧捕获 ===")
    do {
        let demo = try GpuCaptureDemo()
        print("Device: \(demo.device.name)")

        let count = 1024
        let input = (0..<count).map { Float($0) }
        let inBuf = demo.device.makeBuffer(bytes: input, length: count * 4)!
        let bufA = demo.device.makeBuffer(bytes: input, length: count * 4)!   // ping
        let bufB = demo.device.makeBuffer(length: count * 4)!                  // pong
        let tracePath = FileManager.default.currentDirectoryPath + "/demo_capture.gputrace"
        try? FileManager.default.removeItem(atPath: tracePath)

        // —— 配置捕获：对象是命令队列，输出是文件 ——
        let manager = MTLCaptureManager.shared()
        print("捕获支持: \(manager.supportsDestination(.gpuTraceDocument))")
        let desc = MTLCaptureDescriptor()
        desc.captureObject = demo.commandQueue
        desc.destination = .gpuTraceDocument
        desc.outputURL = URL(fileURLWithPath: tracePath)
        try manager.startCapture(with: desc)
        print("▶️ 捕获开始（目标: 命令队列）")

        // —— 被捕获的工作负载：3 个串联的翻倍 pass（ping-pong 缓冲，避免读写同块别名）——
        var src = bufA, dst = bufB
        for pass in 1...3 {
            demo.encodePass(input: src, output: dst, count: count)
            let p = dst.contents().bindMemory(to: Float.self, capacity: count)
            print("  pass \(pass): out[1]=\(String(format: "%.0f", p[1]))（应为 \(Int(pow(2, Double(pass))))）")
            (src, dst) = (dst, src)
        }

        manager.stopCapture()
        print("⏹️ 捕获结束")

        // —— 验证：正确性 + 捕获文件落盘（3 pass 后结果在 src，即最后一次的 dst）——
        let p = src.contents().bindMemory(to: Float.self, capacity: count)
        let allOk = (0..<count).allSatisfy { p[$0] == input[$0] * 8 }   // 翻倍 3 次 = ×8
        print(allOk ? "✅ 计算验证通过：1024 个元素 ×8 全部正确" : "❌ 计算验证失败")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: tracePath),
           let size = attrs[.size] as? Int, size > 0 {
            print("✅ 捕获文件已生成: demo_capture.gputrace（\(size) 字节）")
            print("   用 Xcode 打开它（File → Open）即可逐条查看 3 个 pass 的 GPU 执行明细")
        } else {
            print("❌ 捕获文件未生成（检查磁盘权限）")
        }
    } catch {
        print("❌ \(error.localizedDescription)"); exit(1)
    }
}
