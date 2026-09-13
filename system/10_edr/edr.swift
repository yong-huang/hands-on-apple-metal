import SwiftUI
import Metal
import MetalKit

final class EDRenderView: NSView {
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var pipeline: MTLRenderPipelineState!
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var displayLink: Any!
    var time: Float = 0

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vs(uint vid [[vertex_id]]) {
        float2 p[3] = { {-1,-1},{3,-1},{-1,3} };
        float2 uv[3] = { {0,1},{2,1},{0,-1} };
        return { float4(p[vid],0,1), uv[vid] };
    }
    fragment float4 fs(VOut in [[stage_in]], constant float &time [[buffer(0)]],
                       constant float &edr [[buffer(1)]]) {
        float2 uv = in.uv;
        float d = length(uv - float2(0.5 + 0.3*sin(time), 0.5));
        float glow = smoothstep(0.4, 0.0, d);
        float3 col = float3(0.1, 0.1, 0.15);
        col += glow * float3(0.0, 5.0, 0.0);
        return float4(col, 1);
    }
    """

    override init(frame: NSRect) {
        super.init(frame: .zero)
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        wantsLayer = true
        layer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

        let lib = try! device.makeLibrary(source: Self.shader, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vs")
        d.fragmentFunction = lib.makeFunction(name: "fs")
        d.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try! device.makeRenderPipelineState(descriptor: d)

        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: RunLoop.main, forMode: .common)
        displayLink = link
    }
    required init?(coder: NSCoder) { fatalError("不走 IB") }

    @objc func tick(_ link: Any) {
        var time = Float(CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 10000))
        var edr: Float = 1.0
        if let screen = NSScreen.main {
            edr = Float(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        }
        var t = time

        guard let drawable = metalLayer.nextDrawable(),
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: MTLRenderPassDescriptor()) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&t, length: 4, index: 0)
        enc.setFragmentBytes(&edr, length: 4, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

struct EDRenderViewRep: NSViewRepresentable {
    func makeNSView(context: Context) -> EDRenderView { EDRenderView(frame: .zero) }
    func updateNSView(_ v: EDRenderView, context: Context) {}
}

@main
struct EDRenderApp: App {
    init() {
        if let s = ProcessInfo.processInfo.environment["AUTO_QUIT"], let tv = Double(s), tv > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + tv) { NSApp.terminate(nil) }
        }
    }
    var body: some Scene {
        WindowGroup { EDRenderViewRep().ignoresSafeArea() }
    }
}
