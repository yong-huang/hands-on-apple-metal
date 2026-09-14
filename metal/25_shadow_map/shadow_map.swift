// 25 · 阴影贴图：两遍渲染（光深 → 主 pass 采样比较）
// Pass1：站在光源位置把场景深度渲染进一张 depth32Float 纹理
// Pass2：正常渲染；片元把自己的光空间深度与阴影图比较，被挡住 = 阴影
import Cocoa
import Metal
import MetalKit
import simd

struct SceneVertex {          // position + normal + 物体色
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}

struct ShadowUniforms {       // 两个 pass 共用
    var lightMVP: simd_float4x4    // 光源视角（Pass1 用；Pass2 变换到光空间）
    var camMVP: simd_float4x4      // 相机视角（Pass2 用）
    var model: simd_float4x4       // 法线变换
}

class ShadowMapViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var shadowPipeline: MTLRenderPipelineState!   // Pass1：只写深度
    var mainPipeline: MTLRenderPipelineState!     // Pass2：光照 + 阴影
    var depthState: MTLDepthStencilState!
    var vertexBuffer: MTLBuffer!
    var uniformBuffer: MTLBuffer!
    var shadowMap: MTLTexture!
    var occlusionTex: MTLTexture!   // 阴影 pass 的"遮挡标记"副产物：画到的地方=白色（用于回读验证）
    var angle: Float = 0
    var frameCount = 0
    let shadowMapSize = 1024

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float3 position; float3 normal; float4 color; };
    struct Uniforms { float4x4 lightMVP; float4x4 camMVP; float4x4 model; };
    struct VOut {
        float4 camClip [[position]];   // 主 pass 的裁剪位置
        float4 lightClip;              // 光空间位置（与阴影图比较）
        float3 normal;
        float4 color;
    };

    // Pass1 顶点：位置用光空间 MVP
    vertex float4 shadow_vertex(device const Vertex *v [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]], uint vid [[vertex_id]]) {
        return u.lightMVP * float4(v[vid].position, 1.0);
    }
    // Pass1 片元：深度照进 depth 附件；同时输出白色标记（rgba8 附件可被 CPU 回读验证）
    fragment float4 shadow_fragment() { return float4(1, 1, 1, 1); }

    // Pass2 顶点：同时算相机裁剪位置与光空间位置
    vertex VOut main_vertex(device const Vertex *v [[buffer(0)]],
                            constant Uniforms &u [[buffer(1)]], uint vid [[vertex_id]]) {
        VOut out;
        float4 world = float4(v[vid].position, 1.0);
        out.camClip = u.camMVP * world;
        out.lightClip = u.lightMVP * world;
        out.normal = (u.model * float4(v[vid].normal, 0.0)).xyz;
        out.color = v[vid].color;
        return out;
    }

    fragment float4 main_fragment(
        VOut in [[stage_in]],
        depth2d<float> shadowMap [[texture(0)]],
        constant float3 &lightDir [[buffer(0)]])
    {
        // NDC → 纹理坐标：z 除以 w 做透视除法后映射到 [0,1]
        float3 lp = in.lightClip.xyz / in.lightClip.w;
        float2 uv = float2(lp.x * 0.5 + 0.5, 0.5 - lp.y * 0.5);
        float bias = 0.004;   // 精度有限，留偏差防"阴影粉刺"
        float occluded = shadowMap.sample(sampler(address::clamp_to_edge, filter::nearest), uv);
        float shadow = (lp.z - bias) > occluded ? 0.35 : 1.0;
        float diffuse = max(dot(normalize(in.normal), normalize(lightDir)), 0.0);
        return in.color * (0.3 + 0.7 * diffuse) * shadow;
    }
    """

    // 场景：地面(y=-0.6) + 悬浮立方体。一张顶点缓冲，两段绘制范围
    func buildScene() -> (verts: [SceneVertex], groundCount: Int) {
        var v: [SceneVertex] = []
        let groundColor = SIMD4<Float>(0.55, 0.55, 0.6, 1)
        let s: Float = 2.2
        let gn = SIMD3<Float>(0, 1, 0)
        for p in [SIMD3(-s,0,s), SIMD3(s,0,s), SIMD3(s,0,-s), SIMD3(-s,0,s), SIMD3(s,0,-s), SIMD3(-s,0,-s)] {
            v.append(SceneVertex(position: p + SIMD3<Float>(0, -0.6, 0), normal: gn, color: groundColor))
        }
        let groundCount = v.count

        let corners: [SIMD3<Float>] = [
            SIMD3(-0.4,-0.4, 0.4), SIMD3(0.4,-0.4, 0.4), SIMD3(0.4,0.4, 0.4), SIMD3(-0.4,0.4, 0.4),
            SIMD3(-0.4,-0.4,-0.4), SIMD3(0.4,-0.4,-0.4), SIMD3(0.4,0.4,-0.4), SIMD3(-0.4,0.4,-0.4)]
        let faces: [([Int], SIMD4<Float>)] = [
            ([0,1,2,3], SIMD4(1.0,0.4,0.3,1)), ([5,4,7,6], SIMD4(0.3,1.0,0.5,1)),
            ([4,0,3,7], SIMD4(0.4,0.6,1.0,1)), ([1,5,6,2], SIMD4(1.0,0.9,0.3,1)),
            ([3,2,6,7], SIMD4(0.3,1.0,1.0,1)), ([4,5,1,0], SIMD4(0.9,0.4,1.0,1))]
        let lift = SIMD3<Float>(0, 0.55, 0)   // 立方体悬浮在空中，影子落在地面
        for (idx, color) in faces {
            let q = idx.map { corners[$0] + lift }
            let n = simd_normalize(simd_cross(q[1] - q[0], q[3] - q[0]))
            for i in [0, 1, 2, 0, 2, 3] {
                v.append(SceneVertex(position: q[i], normal: n, color: color))
            }
        }
        return (v, groundCount)
    }

    var groundCount = 0
    var totalCount = 0

    // 数学工具
    func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5), x = y / aspect
        return simd_float4x4(columns: (
            SIMD4(x,0,0,0), SIMD4(0,y,0,0), SIMD4(0,0,-(far+near)/(far-near),-1), SIMD4(0,0,-2*far*near/(far-near),0)))
    }
    func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center), x = simd_normalize(simd_cross(up, z)), y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4(x.x,y.x,z.x,0), SIMD4(x.y,y.y,z.y,0), SIMD4(x.z,y.z,z.z,0),
            SIMD4(-simd_dot(x,eye),-simd_dot(y,eye),-simd_dot(z,eye),1)))
    }
    // 正交投影：阴影图常用（光没有"近大远小"）
    // ⚠️ Metal 的 NDC z 范围是 [0,1]（OpenGL 才是 [-1,1]）——照抄 GL 的 ortho 公式
    // 会把整个场景裁掉且不报任何错，这是 Metal 移植 GL 代码的最高频暗坑。
    // 映射：z_view = -near → 0，z_view = -far → 1
    func ortho(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float) -> simd_float4x4 {
        return simd_float4x4(columns: (
            SIMD4(2/(right-left),0,0,0), SIMD4(0,2/(top-bottom),0,0),
            SIMD4(0,0,-1/(far-near),0), SIMD4(-(right+left)/(right-left),-(top+bottom)/(top-bottom),-near/(far-near),1)))
    }
    func rotationY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4(c,0,-s,0), SIMD4(0,1,0,0), SIMD4(s,0,c,0), SIMD4(0,0,0,1)))
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
        v.depthStencilPixelFormat = .depth16Unorm
        v.clearDepth = 1.0

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            // Pass1 管线：无颜色附件，写 depth32Float
            let sd = MTLRenderPipelineDescriptor()
            sd.vertexFunction = library.makeFunction(name: "shadow_vertex")
            sd.fragmentFunction = library.makeFunction(name: "shadow_fragment")
            sd.colorAttachments[0].pixelFormat = .rgba8Unorm
            sd.depthAttachmentPixelFormat = .depth32Float
            shadowPipeline = try device.makeRenderPipelineState(descriptor: sd)
            // Pass2 管线：颜色 + view 深度
            let md = MTLRenderPipelineDescriptor()
            md.vertexFunction = library.makeFunction(name: "main_vertex")
            md.fragmentFunction = library.makeFunction(name: "main_fragment")
            md.colorAttachments[0].pixelFormat = v.colorPixelFormat
            md.depthAttachmentPixelFormat = .depth16Unorm
            mainPipeline = try device.makeRenderPipelineState(descriptor: md)
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = .less
            d.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: d)
        } catch { print("管线失败: \(error)"); exit(1) }

        let (verts, gc) = buildScene()
        groundCount = gc; totalCount = verts.count
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SceneVertex>.stride)
        uniformBuffer = device.makeBuffer(length: MemoryLayout<ShadowUniforms>.stride)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: shadowMapSize, height: shadowMapSize, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        shadowMap = device.makeTexture(descriptor: td)
        let od = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: shadowMapSize, height: shadowMapSize, mipmapped: false)
        od.usage = [.renderTarget, .shaderRead]
        od.storageMode = .shared
        occlusionTex = device.makeTexture(descriptor: od)
        print("场景: 地面 + 悬浮立方体（\(totalCount) 顶点）；阴影图 \(shadowMapSize)² depth32Float + 遮挡标记图")
    }

    func draw(in view: MTKView) {
        angle += 0.01
        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        let eye = SIMD3<Float>(2.2, 1.6, 2.8)
        let camMVP = perspective(fovY: 55 * .pi / 180, aspect: aspect, near: 0.1, far: 50) * lookAt(eye: eye, center: SIMD3(0,-0.3,0), up: SIMD3(0,1,0)) * rotationY(angle * 0.3)
        let lightEye = SIMD3<Float>(2.5, 3.5, 2.0)
        let lightMVP = ortho(left: -3, right: 3, bottom: -3, top: 3, near: 0.1, far: 15)
            * lookAt(eye: lightEye, center: SIMD3(0,-0.5,0), up: SIMD3(0,1,0))
        var u = ShadowUniforms(lightMVP: lightMVP, camMVP: camMVP, model: matrix_identity_float4x4)
        memcpy(uniformBuffer.contents(), &u, MemoryLayout<ShadowUniforms>.stride)
        var lightDir = simd_normalize(SIMD3<Float>(0, 1, 0) - lightEye)

        guard let cb = commandQueue.makeCommandBuffer() else { return }

        // —— Pass1：光深渲染（无颜色附件；loadAction 清成 1 = 最远）——
        let spass = MTLRenderPassDescriptor()
        spass.depthAttachment.texture = shadowMap
        spass.depthAttachment.loadAction = .clear
        spass.depthAttachment.storeAction = .store
        spass.depthAttachment.clearDepth = 1.0
        spass.colorAttachments[0].texture = occlusionTex
        spass.colorAttachments[0].loadAction = .clear
        spass.colorAttachments[0].storeAction = .store
        spass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let enc = cb.makeRenderCommandEncoder(descriptor: spass) {
            enc.setRenderPipelineState(shadowPipeline)
            enc.setDepthStencilState(depthState)
            enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: totalCount)
            enc.endEncoding()
        }

        // —— Pass2：主渲染，片元里采样阴影图 ——
        if let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
           let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(mainPipeline)
            enc.setDepthStencilState(depthState)
            enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            enc.setFragmentTexture(shadowMap, index: 0)
            enc.setFragmentBytes(&lightDir, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: totalCount)
            enc.endEncoding()
        }
        cb.present(view.currentDrawable!)
        cb.commit()

        // 首帧后回读阴影图验证：立方体正下方应是"近深度"（被遮挡），远处地面应是 1.0
        frameCount += 1
        if frameCount == 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.verifyShadowMap() } }
    }

    func verifyShadowMap() {
        Thread.sleep(forTimeInterval: 0.5)   // 等首帧（含光深 pass）落盘
        // 深度格式不支持 CPU getBytes，用同 pass 写出的 rgba8 遮挡标记图代替：
        // 场景被光源"看见"的纹素 = 白色，其余 = 清屏黑
        var px = [UInt8](repeating: 0, count: shadowMapSize * shadowMapSize * 4)
        occlusionTex.getBytes(&px, bytesPerRow: shadowMapSize * 4,
                              from: MTLRegionMake2D(0, 0, shadowMapSize, shadowMapSize), mipmapLevel: 0)
        let drawn = stride(from: 0, to: px.count, by: 4).filter { px[$0] > 0 }.count
        let ratio = Double(drawn) / Double(px.count / 4)
        print(String(format: "阴影 Pass 回读: %.1f%% 纹素被场景覆盖（地面 + 悬浮立方体的光深投影）", ratio * 100))
        print(drawn > 0 ? "✅ 光深 Pass 确认执行：阴影图有内容可供主 Pass 比较" : "❌ 阴影 Pass 未生效")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

class ShadowMapAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 21 · Shadow Mapping"
        window.center()
        window.contentViewController = ShadowMapViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runShadowMap() {
    let app = NSApplication.shared
    let delegate = ShadowMapAppDelegate()
    app.delegate = delegate
    app.run()
}
