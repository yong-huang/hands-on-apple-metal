// 22 · 实例化渲染：一次 draw 画 400 个物体
// draw call 是 CPU→GPU 最贵的命令之一；实例化把 N 个物体的绘制压成 1 次，
// 每实例的差异（位置/颜色/大小）由 [[instance_id]] 从实例缓冲里取。
import Cocoa
import Metal
import MetalKit
import simd

// 每实例数据：偏移位置 + 颜色 + 大小
struct InstanceData {
    var offset: SIMD2<Float>
    var color: SIMD4<Float>
    var scale: Float
}

// 与着色器中的 Vertex 布局一致
struct Vertex {
    var position: SIMD2<Float>
}

class InstancingViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!      // 一个三角形的 3 个顶点
    var instanceBuffer: MTLBuffer!    // 400 份实例数据
    var instanceCount = 400
    var angle: Float = 0

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Vertex {
        float2 position;   // 单位三角形（中心在原点，边长 ~0.15）
    };
    struct InstanceData {
        float2 offset;
        float4 color;
        float  scale;
    };
    struct RasterizerData {
        float4 position [[position]];
        float4 color;
    };

    vertex RasterizerData vertex_main(
        device const Vertex *verts [[buffer(0)]],
        device const InstanceData *instances [[buffer(1)]],
        uint vid [[vertex_id]],
        uint iid [[instance_id]])          // 第几个实例：实例化的灵魂
    {
        RasterizerData out;
        InstanceData d = instances[iid];
        // 同一份三角形几何，按实例数据缩放、平移
        float2 p = verts[vid].position * d.scale + d.offset;
        out.position = float4(p, 0.0, 1.0);
        out.color = d.color;
        return out;
    }

    fragment float4 fragment_main(RasterizerData in [[stage_in]]) {
        return in.color;
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
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vertex_main")
            desc.fragmentFunction = library.makeFunction(name: "fragment_main")
            desc.colorAttachments[0].pixelFormat = v.colorPixelFormat
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("管线创建失败: \(error)"); exit(1)
        }

        // 几何：一个小三角形（3 顶点，全部实例共享）
        let tri: [Vertex] = [
            Vertex(position: SIMD2( 0.0,  0.08)),
            Vertex(position: SIMD2(-0.07, -0.06)),
            Vertex(position: SIMD2( 0.07, -0.06)),
        ]
        vertexBuffer = device.makeBuffer(bytes: tri, length: 3 * MemoryLayout<Vertex>.stride)

        // 实例：20×20 网格铺满屏幕，颜色按位置渐变，大小略随机（固定种子可复现）
        var seed: UInt64 = 42
        func rand() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 33) & 0xFFFF) / Float(0xFFFF)
        }
        var inst = [InstanceData]()
        let n = 20
        for row in 0..<n {
            for col in 0..<n {
                let x = Float(col) / Float(n - 1) * 1.8 - 0.9
                let y = Float(row) / Float(n - 1) * 1.8 - 0.9
                let color = SIMD4(Float(col) / Float(n - 1), Float(row) / Float(n - 1), 0.6, 1)
                inst.append(InstanceData(offset: SIMD2(x, y), color: color, scale: 0.8 + rand() * 0.6))
            }
        }
        instanceBuffer = device.makeBuffer(bytes: inst, length: inst.count * MemoryLayout<InstanceData>.stride)
        print("几何: 1 个三角形 × \(instanceCount) 个实例 → 每帧只有 1 次 draw call")
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        // 关键一行：instanceCount = 400，顶点仍是 3 个
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: instanceCount)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

class InstancingAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 22 · Instancing (400 instances, 1 draw)"
        window.center()
        window.contentViewController = InstancingViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runInstancing() {
    let app = NSApplication.shared
    let delegate = InstancingAppDelegate()
    app.delegate = delegate
    app.run()
}
