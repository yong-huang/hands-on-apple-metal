// 16 · Compute → Render：同一命令缓冲里"算几何、画几何"
// 与 15 的区别：粒子是"有状态"的（跨帧累积）；这里是"无状态生成"——
// compute 一次性把圆环顶点算进缓冲，render 紧接着把它画成线环，
// GPU 时间线保证同一 commandBuffer 内的执行顺序，CPU 不插手。
import Cocoa
import Metal
import MetalKit

// 与着色器中的 GenUniforms 内存布局一致
struct GenUniforms {
    var count: UInt32
    var radius: Float
}

class ComputeRenderViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var computePipeline: MTLComputePipelineState!
    var renderPipeline: MTLRenderPipelineState!
    var circleBuffer: MTLBuffer!      // compute 的输出 = render 的顶点数据
    let pointCount = 256
    let radius: Float = 0.7

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct GenUniforms {
        uint  count;
        float radius;
    };

    // —— compute：生成几何。一个线程算一个顶点 ——
    kernel void generate_circle(
        device float2 *vertices [[buffer(0)]],
        constant GenUniforms &u [[buffer(1)]],
        uint i [[thread_position_in_grid]])
    {
        if (i >= u.count) { return; }
        float a = float(i) / float(u.count) * 2.0 * M_PI_F;
        vertices[i] = float2(cos(a), sin(a)) * u.radius;
    }

    // —— render：compute 的输出就是这里的顶点缓冲 ——
    vertex float4 vertex_main(
        device const float2 *vertices [[buffer(0)]],
        uint vid [[vertex_id]])
    {
        return float4(vertices[vid], 0.0, 1.0);
    }

    fragment float4 fragment_main(float4 in [[stage_in]]) {
        return float4(0.3, 0.9, 1.0, 1.0);   // 青色线环
    }
    """

    override func viewDidLoad() {
        super.viewDidLoad()
        let v = MTKView(frame: view.bounds, device: MTLCreateSystemDefaultDevice())
        v.autoresizingMask = [.width, .height]
        view.addSubview(v)
        device = v.device
        commandQueue = device.makeCommandQueue()
        v.delegate = self
        v.clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            computePipeline = try device.makeComputePipelineState(
                function: library.makeFunction(name: "generate_circle")!)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vertex_main")
            desc.fragmentFunction = library.makeFunction(name: "fragment_main")
            desc.colorAttachments[0].pixelFormat = v.colorPixelFormat
            renderPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("管线创建失败: \(error)"); exit(1)
        }

        circleBuffer = device.makeBuffer(length: pointCount * 8)
        generateOnceAndVerify()
    }

    // 独立跑一次 compute 并回读验证：每个点必须落在半径 0.7 的圆上
    func generateOnceAndVerify() {
        var u = GenUniforms(count: UInt32(pointCount), radius: radius)
        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(computePipeline)
        enc.setBuffer(circleBuffer, offset: 0, index: 0)
        enc.setBytes(&u, length: MemoryLayout<GenUniforms>.stride, index: 1)
        enc.dispatchThreadgroups(MTLSize(width: (pointCount + 63) / 64, height: 1, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        // CPU 回读抽查 4 个象限点
        let ptr = circleBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: pointCount)
        var ok = true
        for i in stride(from: 0, to: pointCount, by: pointCount / 4) {
            let p = ptr[i]
            let onCircle = abs(simd_length(p) - radius) < 0.001
            ok = ok && onCircle
            print("  顶点[\(i)] = (\(String(format: "%.3f", p.x)), \(String(format: "%.3f", p.y))) |len|=\(String(format: "%.4f", simd_length(p))) \(onCircle ? "✅" : "❌")")
        }
        print(ok ? "✅ compute 生成的 \(pointCount) 个顶点全部落在半径 \(radius) 的圆上" : "❌ 生成验证失败")
    }

    func draw(in view: MTKView) {
        var u = GenUniforms(count: UInt32(pointCount), radius: radius)
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer() else { return }

        // 同一个 commandBuffer：先 compute 重算几何，再 render 消费。
        // GPU 按"编码顺序"执行——这就是 compute→render 的同步机制，无需 CPU 等待。
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(computePipeline)
            enc.setBuffer(circleBuffer, offset: 0, index: 0)
            enc.setBytes(&u, length: MemoryLayout<GenUniforms>.stride, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: (pointCount + 63) / 64, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            enc.endEncoding()
        }
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(renderPipeline)
            enc.setVertexBuffer(circleBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: pointCount)
            enc.endEncoding()
        }
        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

class ComputeRenderAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 16 · Compute → Render"
        window.center()
        window.contentViewController = ComputeRenderViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runComputeRender() {
    let app = NSApplication.shared
    let delegate = ComputeRenderAppDelegate()
    app.delegate = delegate
    app.run()
}
