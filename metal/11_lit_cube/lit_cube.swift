// 11 · 光照立方体：漫反射 + 环境光
// 在 10 的几何上加两样东西：每个顶点的法线、片元里的光照方程
import Cocoa
import Metal
import MetalKit
import simd

// 顶点：位置 + 法线 + 底色
struct Vertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}

// Uniform：MVP 管裁剪位置，model 管法线变换（旋转不改变长度，可直接用）
struct Uniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
}

class LitCubeViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var depthState: MTLDepthStencilState!
    var vertexBuffer: MTLBuffer!
    var uniformBuffer: MTLBuffer!
    var angle: Float = 0

    // MARK: - 着色器：光照方程住在片元里
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex {
        float3 position;
        float3 normal;
        float4 color;
    };
    struct Uniforms {
        float4x4 mvp;
        float4x4 model;
    };
    struct RasterizerData {
        float4 position [[position]];
        float3 normal;
        float4 color;
    };

    vertex RasterizerData vertex_main(
        device const Vertex *vertices [[buffer(0)]],
        constant Uniforms &uni [[buffer(1)]],
        uint vid [[vertex_id]])
    {
        RasterizerData out;
        out.position = uni.mvp * float4(vertices[vid].position, 1.0);
        // 法线用模型矩阵变换（本例 model 只含旋转，无需逆转置修正）
        out.normal = (uni.model * float4(vertices[vid].normal, 0.0)).xyz;
        out.color = vertices[vid].color;
        return out;
    }

    fragment float4 fragment_main(
        RasterizerData in [[stage_in]],
        constant float3 &lightDir [[buffer(0)]])   // 指向光源的方向
    {
        float3 N = normalize(in.normal);
        float3 L = normalize(lightDir);
        // 漫反射：法线与光线夹角越小越亮；负值钳到 0（背面不受光）
        float diffuse = max(dot(N, L), 0.0);
        float ambient = 0.25;                        // 环境光：保证背面不死黑
        return in.color * (ambient + diffuse);
    }
    """

    // 立方体几何：面 → 角点索引 + 面颜色（法线由叉积算出，避免手写）
    static let corners: [SIMD3<Float>] = [
        SIMD3(-0.5, -0.5,  0.5), SIMD3( 0.5, -0.5,  0.5),
        SIMD3( 0.5,  0.5,  0.5), SIMD3(-0.5,  0.5,  0.5),
        SIMD3(-0.5, -0.5, -0.5), SIMD3( 0.5, -0.5, -0.5),
        SIMD3( 0.5,  0.5, -0.5), SIMD3(-0.5,  0.5, -0.5),
    ]
    static let faces: [([Int], SIMD4<Float>)] = [
        ([0, 1, 2, 3], SIMD4(1.0, 0.4, 0.3, 1)),
        ([5, 4, 7, 6], SIMD4(0.3, 1.0, 0.5, 1)),
        ([4, 0, 3, 7], SIMD4(0.4, 0.6, 1.0, 1)),
        ([1, 5, 6, 2], SIMD4(1.0, 0.9, 0.3, 1)),
        ([3, 2, 6, 7], SIMD4(0.3, 1.0, 1.0, 1)),
        ([4, 5, 1, 0], SIMD4(0.9, 0.4, 1.0, 1)),
    ]

    static func makeCubeVertices() -> [Vertex] {
        var verts: [Vertex] = []
        for (idx, color) in faces {
            let q = idx.map { corners[$0] }
            // 面法线 = (边1 × 边2) 归一化，同一面 4 个顶点共享
            let n = simd_normalize(simd_cross(q[1] - q[0], q[3] - q[0]))
            for i in [0, 1, 2, 0, 2, 3] {
                verts.append(Vertex(position: q[i], normal: n, color: color))
            }
        }
        return verts
    }

    // MARK: - 数学工具（与 10 相同的三件套）
    func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5), x = y / aspect
        let zz = -(far + near) / (far - near), w = -2 * far * near / (far - near)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
            SIMD4(0, 0, zz, -1), SIMD4(0, 0, w, 0)))
    }
    func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
    }
    func rotationY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }
    func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
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
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vertex_main")
            desc.fragmentFunction = library.makeFunction(name: "fragment_main")
            desc.colorAttachments[0].pixelFormat = v.colorPixelFormat
            desc.depthAttachmentPixelFormat = .depth16Unorm
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = .less
            d.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: d)
        } catch {
            print("管线创建失败: \(error)"); exit(1)
        }

        let verts = Self.makeCubeVertices()
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Vertex>.stride)
        uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride)
        print("顶点数: \(verts.count)，每顶点带法线；光照 = 环境光 0.25 + 漫反射 dot(N,L)")
    }

    func draw(in view: MTKView) {
        angle += 0.015
        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        let model = rotationY(angle) * rotationX(0.5)
        let viewM = lookAt(eye: SIMD3(0, 0, 3.2), center: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let proj = perspective(fovY: 60.0 * .pi / 180, aspect: aspect, near: 0.01, far: 100)
        var uni = Uniforms(mvp: proj * viewM * model, model: model)
        memcpy(uniformBuffer.contents(), &uni, MemoryLayout<Uniforms>.stride)

        // 光源方向：右上方来光（世界空间固定，立方体转、光不动——明暗面随转动流转）
        var light = SIMD3<Float>(0.6, 0.8, 0.5)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBytes(&light, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

class LitCubeAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 11 · Lit Cube"
        window.center()
        window.contentViewController = LitCubeViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runLitCube() {
    let app = NSApplication.shared
    let delegate = LitCubeAppDelegate()
    app.delegate = delegate
    app.run()
}
