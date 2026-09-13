// 06 · 超分辨率渲染：低分辨率渲染 → 放大呈现
// 内部以 1/4 分辨率渲染动画图案，bilinear 放大到全分辨率呈现。
// 演示超分的核心思想：省 GPU 时间，画质可接受。生产环境建议用 MetalFX（macOS 13+）。
import SwiftUI
import Metal
import MetalKit

// MARK: - SwiftUI 桥接
struct MetalUpscaleViewRep: NSViewRepresentable {
    func makeNSView(context: Context) -> MetalUpscaleView { MetalUpscaleView(frame: .zero) }
    func updateNSView(_ view: MetalUpscaleView, context: Context) {}
}

@main
struct MetalUpscaleApp: App {
    init() {
        if let s = ProcessInfo.processInfo.environment["AUTO_QUIT"], let t = Double(s), t > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }
    }
    var body: some Scene {
        WindowGroup { MetalUpscaleViewRep().ignoresSafeArea().frame(minWidth: 1280, minHeight: 800) }
    }
}

// MARK: - 渲染视图
final class MetalUpscaleView: NSView {
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var scenePipeline: MTLRenderPipelineState!
    var upscalePipeline: MTLRenderPipelineState!
    var lowTex: MTLTexture!
    var uniformBuf: MTLBuffer!
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var frameLink: Any!
    var time: Float = 0
    var frames = 0, fpsStart = Date()

    // 低分辨率场景 shader
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
        float2 uv = in.uv;
        float3 col;
        col.r = 0.5 + 0.5 * sin(uv.x * 60.0 + time * 2.0);
        col.g = 0.5 + 0.5 * sin(uv.y * 40.0 - time * 1.5);
        col.b = 0.5 + 0.5 * sin((uv.x + uv.y) * 30.0 + time);
        float d = length(uv - 0.5);
        col = mix(col, float3(1, 0.9, 0.6), smoothstep(0.35, 0.3, d));
        return float4(col, 1);
    }
    """

    // 放大 shader：bilinear 采样低分辨率纹理
    static let upscaleShader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut vs(uint vid [[vertex_id]]) {
        float2 p[3] = { {-1,-1},{3,-1},{-1,3} };
        float2 uv[3] = { {0,1},{2,1},{0,-1} };
        return { float4(p[vid],0,1), uv[vid] };
    }
    fragment float4 fs(VOut in [[stage_in]],
                       texture2d<float> low [[texture(0)]],
                       sampler smp [[sampler(0)]]) {
        return low.sample(smp, in.uv);
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
        let sd = MTLRenderPipelineDescriptor()
        sd.vertexFunction = lib.makeFunction(name: "vs")
        sd.fragmentFunction = lib.makeFunction(name: "fs")
        sd.colorAttachments[0].pixelFormat = .bgra8Unorm
        scenePipeline = try! device.makeRenderPipelineState(descriptor: sd)

        let ulib = try! device.makeLibrary(source: Self.upscaleShader, options: nil)
        let ud = MTLRenderPipelineDescriptor()
        ud.vertexFunction = ulib.makeFunction(name: "vs")
        ud.fragmentFunction = ulib.makeFunction(name: "fs")
        ud.colorAttachments[0].pixelFormat = .bgra8Unorm
        upscalePipeline = try! device.makeRenderPipelineState(descriptor: ud)

        uniformBuf = device.makeBuffer(length: 4)
        rebuildLowTex()

        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: RunLoop.main, forMode: .common)
        frameLink = link
    }
    required init?(coder: NSCoder) { fatalError("不走 IB") }

    override func layout() {
        super.layout()
        rebuildLowTex()
    }

    func rebuildLowTex() {
        let full = metalLayer.drawableSize
        guard full.width > 1, full.height > 1 else { return }
        let lw = max(Int(full.width / 4), 1)
        let lh = max(Int(full.height / 4), 1)
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: lw, height: lh, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        lowTex = device.makeTexture(descriptor: td)
    }

    @objc func tick(_ link: Any) {
        var t = time
        time += 1.0 / 60.0
        memcpy(uniformBuf.contents(), &t, 4)

        guard let drawable = metalLayer.nextDrawable(),
              let cb = queue.makeCommandBuffer() else { return }

        // Pass 1：低分辨率渲染
        let p1 = MTLRenderPassDescriptor()
        p1.colorAttachments[0].texture = lowTex
        p1.colorAttachments[0].loadAction = .clear
        p1.colorAttachments[0].storeAction = .store
        p1.colorAttachments[0].clearColor = MTLClearColor()
        if let enc = cb.makeRenderCommandEncoder(descriptor: p1) {
            enc.setRenderPipelineState(scenePipeline)
            enc.setFragmentBuffer(uniformBuf, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // Pass 2：放大呈现
        let p2 = MTLRenderPassDescriptor()
        p2.colorAttachments[0].texture = drawable.texture
        p2.colorAttachments[0].loadAction = .clear
        p2.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: p2) {
            enc.setRenderPipelineState(upscalePipeline)
            enc.setFragmentTexture(lowTex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cb.present(drawable)
        cb.commit()

        frames += 1
        if Date().timeIntervalSince(fpsStart) >= 1.0 {
            print(String(format: "超分渲染: %d fps（低分辨率 1/4 + bilinear 放大）", frames))
            frames = 0; fpsStart = Date()
        }
    }
}
