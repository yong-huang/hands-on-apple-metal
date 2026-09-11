// 26 · 延迟着色：G-Buffer（MRT）+ 屏幕空间光照
// 与前向渲染的区别：几何与光照解耦成两个 Pass——
// Pass1 把"表面属性"（反照率、法线）写进多张渲染目标（MRT），
// Pass2 对全屏每个像素独立做光照。光源数量不再拖累几何遍历。
import Cocoa
import Metal
import MetalKit
import simd

struct DVertex { var position: SIMD3<Float>; var normal: SIMD3<Float>; var color: SIMD4<Float> }

class DeferredViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var gbufferPipeline: MTLRenderPipelineState!
    var lightingPipeline: MTLRenderPipelineState!
    var depthState: MTLDepthStencilState!
    var vertexBuffer: MTLBuffer!
    var quadBuffer: MTLBuffer!
    var uniformBuffer: MTLBuffer!
    var albedoTex: MTLTexture!    // G-Buffer 0：反照率
    var normalTex: MTLTexture!    // G-Buffer 1：法线（编码到 [0,1]）
    var depthTex: MTLTexture!
    let W = 1024, H = 768
    var frame = 0

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float3 position; float3 normal; float4 color; };
    struct QuadV  { float2 position; };
    struct Uniforms { float4x4 camMVP; };

    struct GOut {
        float4 position [[position]];
        float4 albedo;    // 经光栅化插值后交给片元
        float4 normal;    // 法线编码到 [0,1]
    };

    vertex GOut gbuffer_vertex(device const Vertex *v [[buffer(0)]],
                               constant Uniforms &u [[buffer(1)]], uint vid [[vertex_id]]) {
        GOut out;
        out.position = u.camMVP * float4(v[vid].position, 1.0);
        out.albedo = v[vid].color;
        out.normal = float4(normalize(v[vid].normal) * 0.5 + 0.5, 1.0);
        return out;
    }

    // MRT 的关键：片元输出结构体用 [[color(n)]] 指明写到第几张渲染目标
    struct GOutFrag {
        float4 albedo [[color(0)]];
        float4 normal [[color(1)]];
    };
    fragment GOutFrag gbuffer_fragment(GOut in [[stage_in]]) {
        return { in.albedo, in.normal };
    }

    struct LOut { float4 position [[position]]; };
    vertex LOut lighting_vertex(device const QuadV *q [[buffer(0)]], uint vid [[vertex_id]]) {
        return { float4(q[vid].position, 0.0, 1.0) };
    }

    // Pass2：每个像素只拿 G-Buffer 数据算光照——光源多也不增加几何成本
    fragment float4 lighting_fragment(
        LOut in [[stage_in]],
        texture2d<float> albedo [[texture(0)]],
        texture2d<float> normal [[texture(1)]])
    {
        uint2 uv = uint2(in.position.xy);
        float3 base = albedo.read(uv).rgb;
        float3 n = normal.read(uv).rgb * 2.0 - 1.0;      // 解码法线
        float3 L = normalize(float3(0.5, 0.8, 0.6));
        float diff = max(dot(n, L), 0.0);
        return float4(base * (0.3 + 0.7 * diff), 1.0);
    }
    """

    // 场景：地面 + 两个不同颜色的悬浮立方体（错开位置，便于验证 G-Buffer）
    func buildScene() -> [DVertex] {
        var v: [DVertex] = []
        let gn = SIMD3<Float>(0, 1, 0)
        let s: Float = 2.5
        for p in [SIMD3(-s,0,s), SIMD3(s,0,s), SIMD3(s,0,-s), SIMD3(-s,0,s), SIMD3(s,0,-s), SIMD3(-s,0,-s)] {
            v.append(DVertex(position: p + SIMD3(0, -0.6, 0), normal: gn, color: SIMD4(0.5, 0.5, 0.55, 1)))
        }
        func cube(_ center: SIMD3<Float>, _ color: SIMD4<Float>) {
            let h: Float = 0.35
            let corners: [SIMD3<Float>] = [
                SIMD3(-h,-h, h), SIMD3(h,-h, h), SIMD3(h,h, h), SIMD3(-h,h, h),
                SIMD3(-h,-h,-h), SIMD3(h,-h,-h), SIMD3(h,h,-h), SIMD3(-h,h,-h)]
            let faces: [([Int], SIMD3<Float>)] = [
                ([0,1,2,3], SIMD3(0,0,1)), ([5,4,7,6], SIMD3(0,0,-1)),
                ([4,0,3,7], SIMD3(-1,0,0)), ([1,5,6,2], SIMD3(1,0,0)),
                ([3,2,6,7], SIMD3(0,1,0)), ([4,5,1,0], SIMD3(0,-1,0))]
            for (idx, n) in faces {
                let q = idx.map { corners[$0] + center }
                for i in [0, 1, 2, 0, 2, 3] {
                    v.append(DVertex(position: q[i], normal: n, color: color))
                }
            }
        }
        cube(SIMD3(-0.7, 0.2, 0), SIMD4(1.0, 0.35, 0.3, 1))
        cube(SIMD3( 0.8, 0.0, 0.3), SIMD4(0.3, 0.6, 1.0, 1))
        return v
    }

    // 数学工具：与 25 相同的约定（透视已输出 Metal 风格 [0,1] 深度）
    func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5), x = y / aspect
        return simd_float4x4(columns: (
            SIMD4(x,0,0,0), SIMD4(0,y,0,0), SIMD4(0,0,-(far+near)/(far-near),-1), SIMD4(0,0,-2*far*near/(far-near),0)))
    }
    func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center), x = simd_normalize(simd_cross(up, z)), yy = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4(x.x,yy.x,z.x,0), SIMD4(x.y,yy.y,z.y,0), SIMD4(x.z,yy.z,z.z,0),
            SIMD4(-simd_dot(x,eye),-simd_dot(yy,eye),-simd_dot(z,eye),1)))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let v = MTKView(frame: view.bounds, device: MTLCreateSystemDefaultDevice())
        v.autoresizingMask = [.width, .height]
        view.addSubview(v)
        device = v.device
        commandQueue = device.makeCommandQueue()
        v.delegate = self
        v.clearColor = MTLClearColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let g = MTLRenderPipelineDescriptor()
            g.vertexFunction = library.makeFunction(name: "gbuffer_vertex")
            g.fragmentFunction = library.makeFunction(name: "gbuffer_fragment")
            g.colorAttachments[0].pixelFormat = .rgba8Unorm   // albedo
            g.colorAttachments[1].pixelFormat = .rgba8Unorm   // normal（MRT 第二张）
            g.depthAttachmentPixelFormat = .depth32Float
            gbufferPipeline = try device.makeRenderPipelineState(descriptor: g)
            let l = MTLRenderPipelineDescriptor()
            l.vertexFunction = library.makeFunction(name: "lighting_vertex")
            l.fragmentFunction = library.makeFunction(name: "lighting_fragment")
            l.colorAttachments[0].pixelFormat = v.colorPixelFormat
            lightingPipeline = try device.makeRenderPipelineState(descriptor: l)
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = .less
            d.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: d)
        } catch { print("管线失败: \(error)"); exit(1) }

        let verts = buildScene()
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<DVertex>.stride)
        // 全屏双三角形（NDC，注意 Metal z ∈ [0,1]，放在 0.5 保证不被裁剪）
        let quad: [SIMD2<Float>] = [SIMD2(-1,-1), SIMD2(1,-1), SIMD2(1,1), SIMD2(-1,-1), SIMD2(1,1), SIMD2(-1,1)]
        quadBuffer = device.makeBuffer(bytes: quad, length: quad.count * MemoryLayout<SIMD2<Float>>.stride)

        func mk(_ fmt: MTLPixelFormat) -> MTLTexture {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: W, height: H, mipmapped: false)
            td.usage = [.renderTarget, .shaderRead]
            td.storageMode = .shared
            return device.makeTexture(descriptor: td)!
        }
        albedoTex = mk(.rgba8Unorm)
        normalTex = mk(.rgba8Unorm)
        depthTex = mk(.depth32Float)
        uniformBuffer = device.makeBuffer(length: 64)
        print("G-Buffer: \(W)×\(H) albedo + normal（MRT 两张）+ depth32Float；场景 \(verts.count) 顶点")
    }

    func draw(in view: MTKView) {
        guard let cb = commandQueue.makeCommandBuffer() else { return }

        // —— Pass1：几何写入 G-Buffer ——
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = albedoTex
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[1].texture = normalTex
        pass.colorAttachments[1].loadAction = .clear
        pass.colorAttachments[1].storeAction = .store
        pass.colorAttachments[1].clearColor = MTLClearColor(red: 0.5, green: 0.5, blue: 1, alpha: 1)
        pass.depthAttachment.texture = depthTex
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1.0
        let aspect = Float(W) / Float(H)
        var cam = perspective(fovY: 55 * .pi / 180, aspect: aspect, near: 0.1, far: 30)
            * lookAt(eye: SIMD3(0.6, 1.4, 3.2), center: SIMD3(0, -0.3, 0), up: SIMD3(0, 1, 0))
        memcpy(uniformBuffer.contents(), &cam, 64)
        if let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(gbufferPipeline)
            enc.setDepthStencilState(depthState)
            enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 54)
            enc.endEncoding()
        }

        // —— Pass2：全屏光照（不再碰几何，只读 G-Buffer）——
        // 离屏方案：直接把光照结果渲到一张 rgba8 上，然后 blit 给 view？
        // 简化：光照结果写到 view（drawables 在这里可用）
        if let drawable = view.currentDrawable, let vp = view.currentRenderPassDescriptor,
           let enc = cb.makeRenderCommandEncoder(descriptor: vp) {
            enc.setRenderPipelineState(lightingPipeline)
            enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(albedoTex, index: 0)
            enc.setFragmentTexture(normalTex, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }
        cb.present(view.currentDrawable!)
        cb.commit()

        frame += 1
        if frame == 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.verifyGBuffer() } }
    }

    // 回读 G-Buffer 全图统计：红/蓝立方体应各占一块，地面法线应大量朝上
    func verifyGBuffer() {
        Thread.sleep(forTimeInterval: 0.2)
        var albedo = [UInt8](repeating: 0, count: W * H * 4)
        var normal = [UInt8](repeating: 0, count: W * H * 4)
        albedoTex.getBytes(&albedo, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        normalTex.getBytes(&normal, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        var red = 0, blue = 0, upNormal = 0, total = W * H
        for i in stride(from: 0, to: albedo.count, by: 4) {
            let (r, g, b) = (Int(albedo[i]), Int(albedo[i+1]), Int(albedo[i+2]))
            if r > 140 && g < 110 && b < 110 { red += 1 }
            if b > 140 && r < 110 && g < 170 { blue += 1 }
            let (ny, nz) = (Int(normal[i+1]), Int(normal[i+2]))
            if ny > 200 && abs(nz - 128) < 40 { upNormal += 1 }   // 编码后朝上 ≈ (128,255,128)
        }
        print(String(format: "G-Buffer 统计: 红立方体 %.2f%% | 蓝立方体 %.2f%% | 朝上法线(地面) %.1f%%",
                     Double(red)/Double(total)*100, Double(blue)/Double(total)*100, Double(upNormal)/Double(total)*100))
        let ok = red > 500 && blue > 500 && upNormal > 50000
        print(ok ? "✅ MRT 验证通过：反照率与法线两张目标都被正确写入" : "❌ G-Buffer 内容异常")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

class DeferredAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 22 · Deferred Shading"
        window.center()
        window.contentViewController = DeferredViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runDeferred() {
    let app = NSApplication.shared
    let delegate = DeferredAppDelegate()
    app.delegate = delegate
    app.run()
}
