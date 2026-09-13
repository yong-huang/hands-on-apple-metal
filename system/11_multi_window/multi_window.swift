import SwiftUI
import Metal
import MetalKit

final class SharedRenderer {
    static let shared = SharedRenderer()
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut vs(uint vid [[vertex_id]]) {
            float2 p[3] = { {-1,-1},{3,-1},{-1,3} };
            float2 uv[3] = { {0,1},{2,1},{0,-1} };
            return { float4(p[vid],0,1), uv[vid] };
        }
        fragment float4 fs(VOut in [[stage_in]], constant float &time [[buffer(0)]],
                           constant float &hue [[buffer(1)]]) {
            float3 col = float3(hue, 0.5, 0.8 - hue * 0.3);
            col.r += 0.3 * sin(in.uv.x * 20.0 + time);
            col.g += 0.2 * sin(in.uv.y * 15.0 - time * 0.7);
            return float4(col, 1);
        }
        """
        let lib = try! device.makeLibrary(source: shader, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vs")
        d.fragmentFunction = lib.makeFunction(name: "fs")
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: d)
    }
}

final class MultiWindowMetalView: NSView {
    var renderer: SharedRenderer!
    var hue: Float = 0.3
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var displayLink: Any!
    var time: Float = 0

    override init(frame: NSRect) {
        super.init(frame: .zero)
        renderer = SharedRenderer.shared
        wantsLayer = true
        layer = CAMetalLayer()
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: RunLoop.main, forMode: .common)
        displayLink = link
    }
    required init?(coder: NSCoder) { fatalError("不走 IB") }

    @objc func tick(_ link: Any) {
        time += 1.0 / 60.0
        guard let drawable = metalLayer.nextDrawable(),
              let cb = renderer.queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: MTLRenderPassDescriptor()) else { return }
        enc.setRenderPipelineState(renderer.pipeline)
        enc.setFragmentBytes(&time, length: 4, index: 0)
        enc.setFragmentBytes(&hue, length: 4, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

struct MultiWindowRep: NSViewRepresentable {
    let hue: Float
    func makeNSView(context: Context) -> MultiWindowMetalView { MultiWindowMetalView(frame: .zero) }
    func updateNSView(_ v: MultiWindowMetalView, context: Context) { v.hue = hue }
}

@main
struct MultiWindowApp: App {
    init() {
        if let s = ProcessInfo.processInfo.environment["AUTO_QUIT"], let t = Double(s), t > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }
    }
    var body: some Scene {
        WindowGroup("A") { MultiWindowRep(hue: 0.3).frame(width: 400, height: 300) }
        WindowGroup("B") { MultiWindowRep(hue: 0.7).frame(width: 400, height: 300) }
    }
}
