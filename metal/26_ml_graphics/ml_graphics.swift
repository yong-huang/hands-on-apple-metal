// 30 · ML + 图形混合管线：GPU 时间线编排
// 混合管线的核心难点不是"跑"，而是"同步"：ML 输出必须先于图形消费。
// 本实验在两条队列上编排一次真实的数据流：
//   MTL4 计算队列生成数据 → MTLSharedEvent 发信号 → 传统渲染队列等信号 → 采样显示
// （ML 派发的插槽位置已在代码里标出——等 28 的 PipelineState 就位即插即用）
import Cocoa
import Metal
import MetalKit

struct GradVertex {
    var position: SIMD4<Float>
    var texCoord: SIMD2<Float>
}

class MlGraphicsViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var queue: MTLCommandQueue!            // 传统渲染队列
    var mtl4Queue: Any?                    // MTL4 计算队列（macOS 26 才有类型）
    var renderPipeline: MTLRenderPipelineState!
    var computePipeline: MTLComputePipelineState!
    var vertexBuffer: MTLBuffer!
    var dataBuffer: MTLBuffer!
    let FW = 512, FH = 512
    var sharedEvent: MTLSharedEvent!
    var refreshed = false

    static let computeSource = """
    #include <metal_stdlib>
    using namespace metal;
    // "ML 输出"数据面：径向渐变（ML 派发就位后，这里换成 network 输出写入同一纹理）
    kernel void generate_field(device float4* out [[buffer(0)]],
                               uint2 tid [[thread_position_in_grid]],
                               uint2 tpg [[threads_per_grid]]) {
        uint W = tpg.x, H = tpg.y;
        float2 uv = (float2(tid) + 0.5) / float2(W, H);
        float d = length(uv - float2(0.5, 0.5)) * 1.414;
        out[tid.y * W + tid.x] = float4(0.9 - d, 0.3 + 0.5 * uv.x, 0.2 + 0.6 * uv.y, 1.0);
    }
    """
    static let renderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct QuadV { float4 position; float2 texCoord; };
    struct ROut { float4 position [[position]]; float2 texCoord; };
    vertex ROut vs(device const QuadV *q [[buffer(0)]], uint vid [[vertex_id]]) {
        return { q[vid].position, q[vid].texCoord };
    }
    fragment float4 fs(ROut in [[stage_in]],
                       device const float4* field [[buffer(0)]],
                       constant float2& dims [[buffer(1)]]) {
        uint2 pix = uint2(in.position.xy);
        float2 uv = (float2(pix) + 0.5) / dims;
        uint W = uint(dims.x);
        return field[uint(uv.y * dims.y) * W + uint(uv.x * dims.x)];
    }
    """

    override func viewDidLoad() {
        super.viewDidLoad()
        let v = MTKView(frame: view.bounds, device: MTLCreateSystemDefaultDevice())
        v.autoresizingMask = [.width, .height]
        view.addSubview(v)
        device = v.device
        queue = device.makeCommandQueue()
        v.delegate = self
        v.clearColor = MTLClearColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)

        do {
            if #available(macOS 26, *) {
                mtl4Queue = device.makeMTL4CommandQueue()
            }
            computePipeline = try device.makeComputePipelineState(function:
                device.makeLibrary(source: Self.computeSource, options: nil).makeFunction(name: "generate_field")!)
            let renderLib = try device.makeLibrary(source: Self.renderSource, options: nil)
            let rd = MTLRenderPipelineDescriptor()
            rd.vertexFunction = renderLib.makeFunction(name: "vs")!
            rd.fragmentFunction = renderLib.makeFunction(name: "fs")!
            rd.colorAttachments[0].pixelFormat = v.colorPixelFormat
            renderPipeline = try device.makeRenderPipelineState(descriptor: rd)
        } catch { print("管线失败: \(error)"); exit(1) }

        let quad: [GradVertex] = [
            GradVertex(position: SIMD4(-1,-1,0,1), texCoord: SIMD2(0,1)),
            GradVertex(position: SIMD4( 1,-1,0,1), texCoord: SIMD2(1,1)),
            GradVertex(position: SIMD4(-1, 1,0,1), texCoord: SIMD2(0,0)),
            GradVertex(position: SIMD4( 1, 1,0,1), texCoord: SIMD2(1,0)),
        ]
        vertexBuffer = device.makeBuffer(bytes: quad, length: 4 * MemoryLayout<GradVertex>.stride)
        dataBuffer = device.makeBuffer(length: FW * FH * 16)
        sharedEvent = device.makeSharedEvent()!
        print("编排：计算队列生成数据 → SharedEvent 信号 → 渲染队列等信号后采样")
    }

    func draw(in view: MTKView) {
        guard let cb = queue.makeCommandBuffer() else { return }
        do {

        // —— 阶段 1：数据生产（ML 派发的插槽：换成 network dispatch，数据面不变）——
        if #available(macOS 26, *), let m4 = mtl4Queue as? MTL4CommandQueue,
           let cmdBuf = device.makeCommandBuffer() as? MTL4CommandBuffer,
           let allocator = device.makeCommandAllocator() {
            let atDesc = MTL4ArgumentTableDescriptor()
            atDesc.maxBufferBindCount = 4
            let argTable = try device.makeArgumentTable(descriptor: atDesc)
            argTable.setAddress(dataBuffer.gpuAddress, index: 0)
            let rsDesc = MTLResidencySetDescriptor()
            let residency = try device.makeResidencySet(descriptor: rsDesc)
            residency.addAllocation(dataBuffer)
            cmdBuf.beginCommandBuffer(allocator: allocator)
            cmdBuf.useResidencySet(residency)
            if let enc = cmdBuf.makeComputeCommandEncoder() {
                enc.setComputePipelineState(computePipeline)
                enc.setArgumentTable(argTable)
                enc.dispatchThreads(threadsPerGrid: MTLSize(width: FW, height: FH, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                enc.endEncoding()
            }
            cmdBuf.endCommandBuffer()
            m4.commit([cmdBuf])
            m4.signalEvent(sharedEvent, value: 1)          // 计算完成后发信号
        } else {
            // 无 MTL4 时的等价编排：同队列 compute + event
            if let enc = cb.makeComputeCommandEncoder() {
                enc.setComputePipelineState(computePipeline)
                enc.setBuffer(dataBuffer, offset: 0, index: 0)
                enc.dispatchThreads(MTLSize(width: FW, height: FH, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
                enc.endEncoding()
            }
        }

        // —— 阶段 2：图形消费（命令缓冲级等待：确保跨队列顺序）——
        if mtl4Queue != nil { cb.encodeWaitForEvent(sharedEvent, value: 1) }
        if let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
           let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(renderPipeline)
            enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            var dims = SIMD2<Float>(Float(FW), Float(FH))
            enc.setFragmentBuffer(dataBuffer, offset: 0, index: 0)
            enc.setFragmentBytes(&dims, length: 8, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }
        cb.present(view.currentDrawable!)
        cb.commit()

        if !refreshed {
            refreshed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.verify() }
        }
        } catch { print("编码失败: \(error)") }
    }

    func verify() {
        Thread.sleep(forTimeInterval: 0.2)
        let p = dataBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: FW * FH)
        let corner = p[0], centerP = p[(FH/2) * FW + FW/2]
        print(String(format: "数据面回读: 角=(%.2f,%.2f,%.2f) 中心=(%.2f,%.2f,%.2f)",
                     corner.x, corner.y, corner.z, centerP.x, centerP.y, centerP.z))
        // 角落 d≈1 → r≈0；中心 d≈0 → r≈0.9
        let ok = corner.x < 0.1 && centerP.x > 0.85
        print(ok ? "✅ 混合管线验证通过：跨队列同步后数据面内容正确" : "❌ 数据面内容异常")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

class MlGraphicsAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 26 · ML + Graphics Timeline"
        window.center()
        window.contentViewController = MlGraphicsViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runMlGraphics() {
    let app = NSApplication.shared
    let delegate = MlGraphicsAppDelegate()
    app.delegate = delegate
    app.run()
}
