// 10 · 3D 立方体：透视投影 + 深度测试
// 从 2D 走进 3D：36 顶点、MVP 矩阵、深度缓冲三件新事物
import Cocoa
import Metal
import MetalKit
import simd

// 顶点结构：3D 位置 + 颜色（与着色器中的布局一一对应）
struct Vertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

// Uniform：每帧更新的 MVP 矩阵
struct Uniforms {
    var mvp: simd_float4x4
}

class CubeViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var depthState: MTLDepthStencilState!     // 深度测试状态：3D 不再是"后画盖前画"
    var vertexBuffer: MTLBuffer!
    var uniformBuffer: MTLBuffer!
    var angle: Float = 0                      // 累积旋转角

    // MARK: - 着色器（内嵌，运行时编译）
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // 与 Swift 侧 struct 内存布局一致（SIMD3<Float>→float3，SIMD4<Float>→float4）
    struct Vertex {
        float3 position;
        float4 color;
    };
    struct Uniforms {
        float4x4 mvp;
    };

    struct RasterizerData {
        float4 position [[position]];   // 裁剪空间位置
        float4 color;                   // 传给片元的颜色
    };

    // 顶点着色器：MVP 矩阵把模型空间直接打到裁剪空间
    vertex RasterizerData vertex_main(
        device const Vertex *vertices [[buffer(0)]],
        constant Uniforms &uni [[buffer(1)]],
        uint vid [[vertex_id]])
    {
        RasterizerData out;
        float4 pos = float4(vertices[vid].position, 1.0);
        out.position = uni.mvp * pos;
        out.color = vertices[vid].color;
        return out;
    }

    fragment float4 fragment_main(RasterizerData in [[stage_in]]) {
        return in.color;
    }
    """

    // MARK: - 立方体几何：8 个角点 × 6 个面 → 36 个顶点（12 个三角形）
    static let corners: [SIMD3<Float>] = [
        SIMD3(-0.5, -0.5,  0.5), SIMD3( 0.5, -0.5,  0.5),   // 0,1 前下
        SIMD3( 0.5,  0.5,  0.5), SIMD3(-0.5,  0.5,  0.5),   // 2,3 前上
        SIMD3(-0.5, -0.5, -0.5), SIMD3( 0.5, -0.5, -0.5),   // 4,5 后下
        SIMD3( 0.5,  0.5, -0.5), SIMD3(-0.5,  0.5, -0.5),   // 6,7 后上
    ]
    // 每面：4 个角点索引（逆时针朝外）+ 面颜色
    static let faces: [([Int], SIMD4<Float>)] = [
        ([0, 1, 2, 3], SIMD4(1, 0, 0, 1)),   // 前 红
        ([5, 4, 7, 6], SIMD4(0, 1, 0, 1)),   // 后 绿
        ([4, 0, 3, 7], SIMD4(0, 0, 1, 1)),   // 左 蓝
        ([1, 5, 6, 2], SIMD4(1, 1, 0, 1)),   // 右 黄
        ([3, 2, 6, 7], SIMD4(0, 1, 1, 1)),   // 上 青
        ([4, 5, 1, 0], SIMD4(1, 0, 1, 1)),   // 下 紫
    ]

    static func makeCubeVertices() -> [Vertex] {
        var verts: [Vertex] = []
        for (idx, color) in faces {
            let q = idx.map { corners[$0] }
            // 两个三角形：0-1-2 与 0-2-3
            for i in [0, 1, 2, 0, 2, 3] {
                verts.append(Vertex(position: q[i], color: color))
            }
        }
        return verts
    }

    // MARK: - 数学工具（simd 手搓，不引第三方库）

    // 透视投影：视锥体压成标准立方体，near/far 之间深度归一
    func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let zz = -(far + near) / (far - near)
        let w = -2 * far * near / (far - near)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
            SIMD4(0, 0, zz, -1), SIMD4(0, 0, w, 0)))
    }

    // 视图矩阵：把世界坐标从"眼睛"角度重新表述
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

    // MARK: - 初始化
    override func viewDidLoad() {
        super.viewDidLoad()
        // 手动创建 MTKView 并挂到控制器视图上（程序化窗口没有 storyboard）
        let v = MTKView(frame: view.bounds, device: MTLCreateSystemDefaultDevice())
        v.autoresizingMask = [.width, .height]
        view.addSubview(v)
        device = v.device
        commandQueue = device.makeCommandQueue()
        v.delegate = self
        v.clearColor = MTLClearColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)
        v.depthStencilPixelFormat = .depth16Unorm   // 声明深度格式后，currentRenderPassDescriptor 自带深度附件
        v.clearDepth = 1.0

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vertex_main")
            desc.fragmentFunction = library.makeFunction(name: "fragment_main")
            desc.colorAttachments[0].pixelFormat = v.colorPixelFormat
            desc.depthAttachmentPixelFormat = .depth16Unorm   // 必须与 view 的深度格式一致
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)

            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = .less        // 更近的片元胜出
            d.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: d)
        } catch {
            print("管线创建失败: \(error)"); exit(1)
        }

        let verts = Self.makeCubeVertices()
        vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Vertex>.stride)
        uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride)
        print("立方体顶点数: \(verts.count)（6 面 × 6 顶点），深度格式 depth16Unorm")
    }

    // MARK: - 每帧：MVP = P × V × M
    func draw(in view: MTKView) {
        angle += 0.02
        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        let model = rotationY(angle) * rotationX(0.55)          // 绕 Y 自转 + 固定俯角
        let viewM = lookAt(eye: SIMD3(0, 0, 3.2), center: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let proj = perspective(fovY: 60.0 * .pi / 180, aspect: aspect, near: 0.01, far: 100)
        let mvp = proj * viewM * model                           // 顺序：从右往左作用

        var uni = Uniforms(mvp: mvp)
        memcpy(uniformBuffer.contents(), &uni, MemoryLayout<Uniforms>.stride)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

// MARK: - 窗口与入口
class CubeAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 10 · 3D Cube"
        window.center()
        window.contentViewController = CubeViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runCube() {
    let app = NSApplication.shared
    let delegate = CubeAppDelegate()
    app.delegate = delegate
    app.run()
}
