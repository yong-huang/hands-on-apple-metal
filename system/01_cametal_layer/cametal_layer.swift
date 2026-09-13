// 27 · 脱离 MTKView：SwiftUI 里直接驱动 CAMetalLayer
// 渲染循环不再由 MTKView 托管：layerClass 换成 CAMetalLayer，
// 用 NSView 的 displayLink 驱动，每帧自己取 drawable、编码、提交。
// os_signpost 给每帧打点，帧率每秒打印一次——验收就靠这两个数。
import SwiftUI
import Metal
import MetalKit
import os

// MARK: - 渲染视图：layerClass 换成 CAMetalLayer 的 NSView
@MainActor
class MetalLayerView: NSView {
    static let signposter = OSSignposter(subsystem: "hands-on-metal", category: "render")
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var uniformBuffer: MTLBuffer!
    var frameLink: Any!                    // NSView.DisplayLink（CLT SDK 接口缺该嵌套类型，存 Any）
    var time: Float = 0
    var lastFrameTimestamp: Double = 0
    var framesThisSecond = 0
    var secondStart = Date()

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }


    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        wantsLayer = true
        // CLT SDK 的 Swift 接口解析不出 layerClass 重写点，直接替换 layer 实例（等效）
        layer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true                            // 只作呈现目标，驱动可做最大优化

        let source = Self.shaderSource
        let library = try! device.makeLibrary(source: source, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vertex_main")
        desc.fragmentFunction = library.makeFunction(name: "fragment_main")
        desc.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
        pipelineState = try! device.makeRenderPipelineState(descriptor: desc)

        uniformBuffer = device.makeBuffer(length: 16)
        syncDrawableSize()

        // 帧驱动：displayLink 与屏幕刷新对齐（本实验锁 60）
        let link = displayLink(target: self, selector: #selector(step(_:)))   // NSView 实例方法
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 58, maximum: 62, preferred: 60)   // 锁 60fps
        link.add(to: RunLoop.main, forMode: .common)
        frameLink = link
    }

    required init?(coder: NSCoder) { fatalError("不走 IB") }

    // 窗口/视图尺寸变化时同步 drawable 分辨率（按 backing 像素算，Retina 不糊）
    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    func syncDrawableSize() {
        metalLayer.drawableSize = convertToBacking(metalLayer.bounds.size)
    }

    // MARK: - 每帧：取 drawable → 编码 → 提交
    @objc func step(_ link: Any) {
        let signpostID = Self.signposter.makeSignpostID()
        let state = Self.signposter.beginInterval("frame", id: signpostID)
        defer { Self.signposter.endInterval("frame", state) }

        guard let drawable = metalLayer.nextDrawable() else { return }
        time += 1.0 / 60.0
        let uniforms: [Float] = [
            Float(drawable.texture.width), Float(drawable.texture.height), time, 0
        ]
        memcpy(uniformBuffer.contents(), uniforms, 16)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        // 无顶点缓冲的全屏三角形：三个越界大顶点铺满 NDC，片段覆盖整个屏幕
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        // 帧率统计：每秒打印一次
        framesThisSecond += 1
        let now = Date()
        if now.timeIntervalSince(secondStart) >= 1.0 {
            let fps = Double(framesThisSecond) / now.timeIntervalSince(secondStart)
            print(String(format: "fps: %.1f（%d 帧提交成功）", fps, framesThisSecond))
            framesThisSecond = 0
            secondStart = now
        }
    }

    // MARK: - 着色器：全屏三角形 + 随时间流动的渐变
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 size;   // drawable 分辨率
        float  time;
        float  pad;
    };

    // 全屏三角形：三个顶点直接越界铺满 NDC，省一个顶点缓冲
    vertex float4 vertex_main(uint vid [[vertex_id]]) {
        float2 pos[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        return float4(pos[vid], 0.0, 1.0);
    }

    // 片元：UV 渐变随 time 流动——"清屏渐变"本体的全部数学
    fragment float4 fragment_main(
        float4 pix [[position]],
        constant Uniforms &u [[buffer(0)]])
    {
        float2 uv = pix.xy / u.size;
        float3 a = float3(0.10, 0.55, 0.85);
        float3 b = float3(0.85, 0.25, 0.45);
        float3 c = mix(a, b, 0.5 + 0.5 * sin(uv.x * 3.14159 + u.time));
        c += 0.15 * (1.0 - uv.y);
        return float4(c, 1.0);
    }
    """
}

// MARK: - SwiftUI 桥接
struct MetalLayerViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> MetalLayerView { MetalLayerView(frame: .zero) }
    func updateNSView(_ view: MetalLayerView, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        MetalLayerViewRepresentable()
            .ignoresSafeArea()
            .overlay(alignment: .topLeading) {
                Text("CAMetalLayer × SwiftUI")
                    .font(.headline).padding(8)
                    .foregroundStyle(.white.opacity(0.85))
            }
    }
}

@main
struct CametalLayerApp: App {
    init() {
        // 脚本化验证：AUTO_QUIT=<秒> 到点自动退出
        if let s = ProcessInfo.processInfo.environment["AUTO_QUIT"], let t = Double(s), t > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                NSApplication.shared.terminate(nil)
            }
        }
    }
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 800, height: 600)
        }
    }
}
