// 28 · Metal 4 · MTL4 命令栈与 ML Command Encoder
// Metal 4 的三大架构变化全部落地在本实验：
//   1) Allocator 显式管理命令内存；Buffer 显式 begin/end
//   2) 资源绑定改用 ArgumentTable（不再逐 draw setBuffer）
//   3) 资源常驻要求 ResidencySet；完成同步用 SharedEvent
// ML 派发的前置条件（已编译 Core ML 包）做如实探测。
import Metal
import Foundation

func runMlEncoder() {
    setenv("APPINTENTS_DISABLE", "1", 1)
    print("=== Metal 4 · MTL4 命令栈 ===")
    guard #available(macOS 26, *), let device = MTLCreateSystemDefaultDevice() else {
        print("❌ 需要 macOS 26+ 的 Metal 设备"); exit(1)
    }
    print("Device: \(device.name)")

    // —— 1) 新命令栈：Allocator（命令内存）/ Queue / Buffer ——
    guard let allocator = device.makeCommandAllocator() else { print("❌ allocator 创建失败"); exit(1) }
    guard let queue = device.makeMTL4CommandQueue() else { print("❌ MTL4 队列创建失败"); exit(1) }
    guard let cmdBuf = device.makeCommandBuffer() as? MTL4CommandBuffer else { print("❌ 命令缓冲创建失败"); exit(1) }
    print("✅ Allocator + MTL4Queue + CommandBuffer 就绪")

    let count = 1024
    do {
        let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;
        kernel void double_array(device const float* in [[buffer(0)]],
                                 device float* out [[buffer(1)]],
                                 uint i [[thread_position_in_grid]]) {
            out[i] = in[i] * 2.0;
        }
        """, options: nil)
        let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "double_array")!)
        let input = (0..<count).map { Float($0) }
        let inBuf = device.makeBuffer(bytes: input, length: count * 4)!
        let outBuf = device.makeBuffer(length: count * 4)!

        // —— 2) 资源常驻：MTL4 必须把用到的资源登记进 ResidencySet ——
        let rsDesc = MTLResidencySetDescriptor()
        rsDesc.label = "lab28"
        let residency = try device.makeResidencySet(descriptor: rsDesc)
        residency.addAllocations([inBuf, outBuf])

        // —— 3) 参数表：Metal 4 的资源绑定方式（对比旧 API 的 setBuffer）——
        let atDesc = MTL4ArgumentTableDescriptor()
        atDesc.maxBufferBindCount = 4
        let argTable = try device.makeArgumentTable(descriptor: atDesc)
        argTable.setAddress(inBuf.gpuAddress, index: 0)   // 对应 kernel 的 [[buffer(0)]]
        argTable.setAddress(outBuf.gpuAddress, index: 1)  // 对应 [[buffer(1)]]

        // —— 4) 显式生命周期：begin → 编码 → end → 批量 commit ——
        cmdBuf.beginCommandBuffer(allocator: allocator)
        cmdBuf.useResidencySet(residency)
        if let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(pipeline)
            enc.setArgumentTable(argTable)
            enc.dispatchThreadgroups(threadgroupsPerGrid: MTLSize(width: (count + 63) / 64, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding()
        }
        cmdBuf.endCommandBuffer()

        // —— 5) 完成同步：MTL4 没有 waitUntilCompleted，用 SharedEvent ——
        let event = device.makeSharedEvent()!
        queue.commit([cmdBuf])
        queue.signalEvent(event, value: 1)     // 排在已提交缓冲之后
        event.wait(untilSignaledValue: 1, timeoutMS: 5000)

        let p = outBuf.contents().bindMemory(to: Float.self, capacity: count)
        let ok = (0..<count).allSatisfy { p[$0] == input[$0] * 2 }
        print(ok ? "✅ MTL4 栈 compute kernel 验证通过：1024 元素 ×2 全对" : "❌ 计算结果错误")

        // —— 6) ML Command Encoder：如实探测前置条件 ——
        // ML 派发还需要 MTL4MachineLearningPipelineState，它来自"已编译的 Core ML 包"，
        // 该编译步骤目前只有 Xcode 26 构建链提供——命令行环境无法补齐。
        cmdBuf.beginCommandBuffer(allocator: allocator)
        let mlEncoder = cmdBuf.makeMachineLearningCommandEncoder()
        cmdBuf.endCommandBuffer()
        print(mlEncoder != nil
            ? "⚠️ ML Command Encoder 可创建，但派发网络还需 Xcode 26 编译的 Core ML 包（.mlpackage → PipelineState）——这是本实验未完成 ML 派发的唯一原因，硬件与系统已就绪"
            : "❌ machineLearningCommandEncoder 不可用")
    } catch {
        print("❌ \(error.localizedDescription)"); exit(1)
    }
}
