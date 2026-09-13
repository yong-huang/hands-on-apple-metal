// 12 · 帧率 HUD：帧时间曲线画进 Metal
import SwiftUI
import Metal
import MetalKit

@main
struct DisplayHUDApp: App {
    init() {
        if let s = ProcessInfo.processInfo.environment["AUTO_QUIT"], let t = Double(s), t > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }
    }
    var body: some Scene {
        WindowGroup { DisplayHUDViewRep().ignoresSafeArea().frame(minWidth: 800, minHeight: 600) }
    }
}

final class DisplayHUDView: NSView {
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var scenePipeline: MTLRenderPipelineState!
    var hudPipeline: MTLRenderPipelineState!
    var frameLink: Any!
    var frameTimes: [Float] = Array(repeating: 1.0/60.0, count: 120)
    var frameIdx = 0
    var lastTick = CFAbsoluteTimeGetCurrent()
    var time: Float = 0
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // 场景 shader
    static let sceneShader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vs(uint vid [[vertex_id]]) {
        float2 p[3] = { {-1,-1},{3,-1},{-1,3} };
        float2 uv[3] = { {0,1},{2,1},{0,-1} };
        return { float4(p[vid],0,1), uv[vid] };
    }
    fragment float4 fs(VOut in [[stage_in]], constant float &time [[buffer(0)]]) {
        return float4(0.1 + 0.1*sin(time), 0.2, 0.3, 1);
    }
    """

    // HUD shader：帧时间曲线
    static let hudShader = """
    #include <metal_stdlib>
    using namespace metal;
    struct HudVOut { float4 pos [[position]]; };
    vertex HudVOut hud_vs(device const float *frameTimes [[buffer(0)]], uint vid [[vertex_id]]) {
        float x = float(vid) / 119.0 * 2.0 - 1.0;
        float ms = frameTimes[vid] * 1000.0;
        float y = clamp(ms / 16.67 * 2.0 - 1.0, -1.0, 1.0);
        return { float4(x, y, 0, 1) };
    }
    fragment float4 hud_fs() {
        return float4(0.2, 1.0, 0.3, 1.0);
    }
    """

    override init(frame: NSRect) {
        super.init(frame: .zero)
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        wantsLayer = true
        layer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm

        let lib = try! device.makeLibrary(source: Self.sceneShader, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vs")
        d.fragmentFunction = lib.makeFunction(name: "fs")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        scenePipeline = try! device.makeRenderPipelineState(descriptor: d)

        let hlib = try! device.makeLibrary(source: Self.hudShader, options: nil)
        let hd = MTLRenderPipelineDescriptor()
        hd.vertexFunction = hlib.makeFunction(name: "hud_vs")
        hd.fragmentFunction = hlib.makeFunction(name: "hud_fs")
        hd.colorAttachments[0].pixelFormat = .bgra8Unorm
        hudPipeline = try! device.makeRenderPipelineState(descriptor: hd)
    }
    required init?(coder: NSCoder) { fatalError("不走 IB") }

    @objc func tick(_ link: Any) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = Float(now - lastTick)
        lastTick = now
        frameTimes[frameIdx % 120] = dt
        frameIdx += 1
        time += dt

        guard let drawable = metalLayer.nextDrawable(),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: MTLRenderPassDescriptor()) else { return }
        enc.setRenderPipelineState(scenePipeline)
        enc.setFragmentBytes(&time, length: 4, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

struct DisplayHUDViewRep: NSViewRepresentable {
    func makeNSView(context: Context) -> DisplayHUDView { DisplayHUDView(frame: .zero) }
    func updateNSView(_ v: DisplayHUDView, context: Context) {}
}
