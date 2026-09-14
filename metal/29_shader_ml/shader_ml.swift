// 29 · Shader ML 突破：tensor kernel 从语法到全链路派发
// 三轮真实实验（全部本机 2026-09 实测）：
//   第一轮  运行时 makeLibrary 编 tensor 内核 → 前端不含 tensor 模块，失败
//   第二轮  Xcode 工具链 metal CLI + 正确的 MSL4 tensor 语法 → 编译通过出 metallib
//   第三轮  MTL4 命令栈派发 tensor kernel：填充 → ×2 → 写回 buffer → CPU 验证 ✅
// 关键语法（WWDC25 Session 262）：tensor<device float, dextents<int, 1>> 配 [[buffer(i)]] 绑定，
//   而非 extents<uint,N,tensor_handle,tensor_offset> 配 [[binding(i)]]。
// 边界：MTL4 ML Command Encoder 的 ML pipeline 仍需 Core ML GPU 特化二进制（见实验 24）。
import Metal
import Foundation

let tensorKernel = """
#include <metal_stdlib>
#include <metal_tensor>
using namespace metal;

kernel void fill_tensor(tensor<device float, dextents<int, 1>> out [[buffer(0)]],
                        uint i [[thread_position_in_grid]]) {
    out[i] = float(i);
}

kernel void double_tensor(tensor<device float, dextents<int, 1>> in  [[buffer(0)]],
                          tensor<device float, dextents<int, 1>> out [[buffer(1)]],
                          uint i [[thread_position_in_grid]]) {
    out[i] = in[i] * 2.0;
}

kernel void tensor_to_buffer(tensor<device float, dextents<int, 1>> in [[buffer(0)]],
                             device float* out [[buffer(1)]],
                             uint i [[thread_position_in_grid]]) {
    out[i] = in[i];
}
"""

let N = 1024

func runShaderMl() {
    setenv("APPINTENTS_DISABLE", "1", 1)
    print("=== Shader ML：tensor kernel 全链路 ===")
    guard #available(macOS 26, *), let device = MTLCreateSystemDefaultDevice() else {
        print("❌ 需要 macOS 26+ 的 Metal 设备"); exit(1)
    }
    print("Device: \(device.name) | macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

    // —— 第一轮：运行时 makeLibrary（前端不含 tensor 模块）——
    do {
        _ = try device.makeLibrary(source: tensorKernel, options: nil)
        print("第一轮（运行时 makeLibrary）：✅ 编译通过（前端已支持 tensor，可直接派发）")
    } catch {
        let msg = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? "\(error)"
        let key = msg.split(separator: "\n").first { $0.contains(": error:") } ?? Substring(msg)
        print("第一轮（运行时 makeLibrary）：❌ \(key.trimmingCharacters(in: .whitespaces).prefix(120))")
    }

    // —— 第二轮：Xcode 工具链 metal CLI，正确的 MSL4 tensor 语法 ——
    let devdir = "/Applications/Xcode.app/Contents/Developer"
    guard FileManager.default.fileExists(atPath: devdir) else {
        print("❌ 未找到完整 Xcode，第二轮跳过"); return
    }
    let tmp = NSTemporaryDirectory()
    let src = tmp + "shader_ml_kernel.metal"
    let air = tmp + "shader_ml_kernel.air"
    let mlib = tmp + "shader_ml_kernel.metallib"
    try? tensorKernel.write(toFile: src, atomically: true, encoding: .utf8)

    let env = ProcessInfo.processInfo.environment.merging(["DEVELOPER_DIR": devdir]) { _, new in new }
    func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let err = Pipe(); p.standardError = err
        try? p.run(); p.waitUntilExit()
        return (p.terminationStatus, String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
    // metal CLI 在工具链 cryptex 中，由 xcrun --find 定位
    let findPipe = Pipe()
    let finder = Process()
    finder.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    finder.arguments = ["--find", "metal"]
    finder.environment = env
    finder.standardOutput = findPipe
    finder.standardError = Pipe()
    try? finder.run(); finder.waitUntilExit()
    let metalPath = String(data: findPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !metalPath.isEmpty else { print("❌ 工具链内未找到 metal CLI"); return }
    print("第二轮（Xcode metal CLI）：\(URL(fileURLWithPath: metalPath).lastPathComponent)")

    let (st2, diag) = run(metalPath, ["-c", src, "-o", air])
    guard st2 == 0 else {
        let key = diag.split(separator: "\n").first { $0.contains(": error:") } ?? Substring("（无诊断）")
        print("❌ 第二轮编译失败：\(key.trimmingCharacters(in: .whitespaces).prefix(130))")
        return
    }
    let toolchainBin = (URL(fileURLWithPath: metalPath).deletingLastPathComponent().path)
    let (st3, d3) = run(toolchainBin + "/metallib", [air, "-o", mlib])
    guard st3 == 0 else { print("❌ metallib 打包失败：\(d3.prefix(120))"); return }
    print("✅ 第二轮：tensor kernel 编译通过 → metallib（dextents<int,1> + [[buffer(i)]] 语法）")

    // —— 第三轮：MTL4 命令栈全链路派发 ——
    runChain(library: { try device.makeLibrary(URL: URL(fileURLWithPath: mlib)) })
}

func runChain(library: () throws -> MTLLibrary) {
    guard #available(macOS 26, *), let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeMTL4CommandQueue(),
          let allocator = try? device.makeCommandAllocator(),
          let cb0 = device.makeCommandBuffer(), let cmdBuf = cb0 as? MTL4CommandBuffer else {
        print("❌ MTL4 命令栈创建失败"); exit(1)
    }
    do {
        let lib = try library()
        func pso(_ n: String) throws -> any MTLComputePipelineState {
            try device.makeComputePipelineState(function: lib.makeFunction(name: n)!)
        }
        let pFill = try pso("fill_tensor"), pDouble = try pso("double_tensor"), pToBuf = try pso("tensor_to_buffer")

        func tensor() throws -> any MTLTensor {
            let d = MTLTensorDescriptor()
            d.dataType = .float32
            d.dimensions = MTLTensorExtents(__rank: 1, values: [N])!
            d.usage = [.compute]
            return try device.makeTensor(descriptor: d)
        }
        let tIn = try tensor(), tOut = try tensor()
        let bufA = device.makeBuffer(length: N * 4)!

        let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        residency.addAllocations([tIn, tOut, bufA])
        let atDesc = MTL4ArgumentTableDescriptor()
        atDesc.maxBufferBindCount = 4
        let argTable = try device.makeArgumentTable(descriptor: atDesc)

        func dispatch(_ pipeline: any MTLComputePipelineState,
                      _ res: [(MTLResourceID, Int)], _ addr: [(MTLGPUAddress, Int)]) {
            for (r, i) in res { argTable.setResource(r, bufferIndex: i) }
            for (a, i) in addr { argTable.setAddress(a, index: i) }
            if let enc = cmdBuf.makeComputeCommandEncoder() {
                enc.setComputePipelineState(pipeline)
                enc.setArgumentTable(argTable)
                enc.dispatchThreadgroups(threadgroupsPerGrid: MTLSize(width: N / 64, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                enc.endEncoding()
            }
        }

        cmdBuf.beginCommandBuffer(allocator: allocator)
        cmdBuf.useResidencySet(residency)
        dispatch(pFill,   [(tIn.gpuResourceID, 0)], [])
        dispatch(pDouble, [(tIn.gpuResourceID, 0), (tOut.gpuResourceID, 1)], [])
        dispatch(pToBuf,  [(tOut.gpuResourceID, 0)], [(bufA.gpuAddress, 1)])
        cmdBuf.endCommandBuffer()

        let event = device.makeSharedEvent()!
        queue.commit([cmdBuf])
        queue.signalEvent(event, value: 1)
        event.wait(untilSignaledValue: 1, timeoutMS: 5000)

        let p = bufA.contents().bindMemory(to: Float.self, capacity: N)
        let ok = (0..<N).allSatisfy { p[$0] == Float($0) * 2 }
        print(ok
            ? "✅ 第三轮：tensor 全链路验证通过——填充 → ×2 → 写回 buffer，\(N) 元素全对（p[0]=\(p[0]) p[1]=\(p[1]) p[\(N-1)]=\(p[N-1])）"
            : "❌ 第三轮结果错误 p[0]=\(p[0]) p[1]=\(p[1])")
        print("""

        📌 结论（本机 2026-09 实测）：
           1. tensor kernel 语法：tensor<device T, dextents<int, R>> + [[buffer(i)]]，普通 kernel 入口即可
           2. 运行时 makeLibrary 前端不含 tensor 模块；Xcode 工具链 metal CLI 可编译出 metallib
           3. MTL4 栈派发：argTable.setResource(tensor.gpuResourceID, bufferIndex:) 完成张量绑定
           4. MTLTensor 无 CPU 指针（buffer=nil），数据进出靠 kernel 搬运（fill / tensor_to_buffer）
           5. 边界：ML Command Encoder 的 ML pipeline 仍需 Core ML GPU 特化二进制（实验 24）
        """)
    } catch {
        print("❌ \(error.localizedDescription)"); exit(1)
    }
}
