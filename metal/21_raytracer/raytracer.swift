// 21 · 光线追踪基础：MPSRayIntersector
// 与光栅化完全不同的成像方式：从相机向每个像素发一根光线，
// 求最近交点，按重心坐标插值顶点色。本实验场景是两个彩色三角形，
// 交点求交由 MPS 加速结构完成，着色在 CPU 完成——回读即验证。
import Cocoa
import Metal
import MetalKit
import MetalPerformanceShaders
import simd

struct TracedVertex {         // 三角形场景：位置 + 颜色
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

// MPS 的 ray/intersection 结构体只定义在 MSL 头文件里，Swift 侧必须
// 手写内存布局完全一致的镜像（实测确定的布局，README 有验证记录）。
// 对应 rayDataType = .originDirection：float3 origin; float3 direction;
struct Ray {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float>
}
// 对应 intersectionDataType = .distancePrimitiveIndexCoordinates：
// float distance; uint primitiveIndex; float2 coordinates;
// 未命中时 distance = -1、primitiveIndex = 0xFFFFFFFF
struct Hit {
    var distance: Float
    var primitiveIndex: UInt32
    var coordinates: SIMD2<Float>
}

class RaytracerViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var renderPipeline: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!       // 全屏四边形（显示用）
    var resultTexture: MTLTexture!     // 光追结果（CPU 写入像素）

    let W = 512, H = 512
    // 场景：两个三角形拼成斜放的彩色四边形，位于 z=-3
    let scene: [TracedVertex] = [
        TracedVertex(position: SIMD3(-1.5, -1.0, -3.0), color: SIMD4(1.0, 0.3, 0.3, 1)),
        TracedVertex(position: SIMD3( 1.5, -1.0, -3.0), color: SIMD4(0.3, 1.0, 0.3, 1)),
        TracedVertex(position: SIMD3( 1.5,  1.5, -3.5), color: SIMD4(0.3, 1.0, 0.3, 1)),
        TracedVertex(position: SIMD3(-1.5, -1.0, -3.0), color: SIMD4(1.0, 0.3, 0.3, 1)),
        TracedVertex(position: SIMD3( 1.5,  1.5, -3.5), color: SIMD4(0.3, 0.3, 1.0, 1)),
        TracedVertex(position: SIMD3(-1.5,  1.5, -3.0), color: SIMD4(1.0, 0.3, 0.3, 1)),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        let v = MTKView(frame: view.bounds, device: MTLCreateSystemDefaultDevice())
        v.autoresizingMask = [.width, .height]
        view.addSubview(v)
        device = v.device
        commandQueue = device.makeCommandQueue()
        v.delegate = self
        v.clearColor = MTLClearColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)

        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct QuadVertex { float4 position; float2 texCoord; };
        struct RasterizerData { float4 position [[position]]; float2 texCoord; };
        vertex RasterizerData vs(device const QuadVertex *q [[buffer(0)]], uint vid [[vertex_id]]) {
            return { q[vid].position, q[vid].texCoord };
        }
        fragment float4 fs(RasterizerData in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]]) {
            return tex.sample(s, in.texCoord);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vs")
            desc.fragmentFunction = library.makeFunction(name: "fs")
            desc.colorAttachments[0].pixelFormat = v.colorPixelFormat
            renderPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch { print("管线失败: \(error)"); exit(1) }

        let quad: [QuadVertexLike] = [
            QuadVertexLike(position: SIMD4(-1, -1, 0, 1), texCoord: SIMD2(0, 1)),
            QuadVertexLike(position: SIMD4( 1, -1, 0, 1), texCoord: SIMD2(1, 1)),
            QuadVertexLike(position: SIMD4(-1,  1, 0, 1), texCoord: SIMD2(0, 0)),
            QuadVertexLike(position: SIMD4( 1,  1, 0, 1), texCoord: SIMD2(1, 0)),
        ]
        vertexBuffer = device.makeBuffer(bytes: quad, length: 4 * MemoryLayout<QuadVertexLike>.stride)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
        td.usage = [.shaderRead]
        td.storageMode = .shared
        resultTexture = device.makeTexture(descriptor: td)
        renderOnce()
    }

    // MARK: - 一次完整光追
    func renderOnce() {
        // 1) 场景几何（scene 数组留着 CPU 着色用；加速结构在下面用纯位置缓冲重建）
        // 2) 生成主光线：针孔相机，从原点穿过每个像素
        //    注意：加速结构只吃"紧凑的纯位置"缓冲（float3 × 3N），不能把颜色混在一起
        let positions = scene.map { $0.position }
        let posBuffer = device.makeBuffer(bytes: positions, length: positions.count * MemoryLayout<SIMD3<Float>>.stride)!
        let accel = MPSTriangleAccelerationStructure(device: device!)
        accel.vertexBuffer = posBuffer
        accel.triangleCount = 2
        accel.rebuild()

        var rays = [Ray](repeating: Ray(origin: .zero, direction: .zero), count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let u = Float(x) / Float(W) * 2 - 1
                let vv = 1 - Float(y) / Float(H) * 2
                let d = simd_normalize(SIMD3(u, vv, -1.8))
                rays[y * W + x] = Ray(origin: SIMD3(0, 0, 0), direction: d)
            }
        }
        let rayBuffer = device.makeBuffer(bytes: rays, length: rays.count * MemoryLayout<Ray>.stride)!
        let interBuffer = device.makeBuffer(length: W * H * MemoryLayout<Hit>.stride)!

        // 3) MPS 求交：数据布局由 rayDataType/intersectionDataType 声明
        let intersector = MPSRayIntersector(device: device!)
        intersector.rayDataType = .originDirection
        intersector.intersectionDataType = .distancePrimitiveIndexCoordinates
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        intersector.encodeIntersection(
            commandBuffer: cb,
            intersectionType: .nearest,
            rayBuffer: rayBuffer,
            rayBufferOffset: 0,
            intersectionBuffer: interBuffer,
            intersectionBufferOffset: 0,
            rayCount: W * H,
            accelerationStructure: accel)
        cb.commit()
        cb.waitUntilCompleted()

        // 4) CPU 着色：命中 → 重心坐标插顶点色；未命中 → 背景色
        let hits = interBuffer.contents().bindMemory(to: Hit.self, capacity: W * H)
        var px = [UInt8](repeating: 0, count: W * H * 4)
        var hitCount = 0
        for i in 0..<(W * H) {
            let x = i % W, y = i / W
            let hit = hits[i]
            var c = SIMD4<Float>(0.055, 0.07, 0.11, 1)     // 背景色（与窗口一致）
            if hit.distance >= 0 {   // distance >= 0 表示命中；未命中 = -1 + prim=0xFFFFFFFF
                hitCount += 1
                // Apple 采样约定：w0 = 1-x-y，w1 = x，w2 = y
                let w0 = 1 - hit.coordinates.x - hit.coordinates.y
                let idx = Int(hit.primitiveIndex) * 3
                let c0 = scene[idx].color, c1 = scene[idx+1].color, c2 = scene[idx+2].color
                c = c0 * w0 + c1 * hit.coordinates.x + c2 * hit.coordinates.y
            }
            let o = (y * W + x) * 4
            px[o] = UInt8(max(0, min(255, c[0] * 255)))
            px[o+1] = UInt8(max(0, min(255, c[1] * 255)))
            px[o+2] = UInt8(max(0, min(255, c[2] * 255)))
            px[o+3] = 255
        }
        resultTexture.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
        print("光追完成: \(W*H) 根光线，命中 \(hitCount) 根（命中率 \(String(format: "%.1f", Double(hitCount)/Double(W*H)*100))%）")

        // 5) 验证：中心必命中（应为混合色非背景），左上角必未命中（应等于背景）
        func pixelAt(_ x: Int, _ y: Int) -> [UInt8] {
            let o = (y * W + x) * 4
            return [px[o], px[o+1], px[o+2]]
        }
        let center = pixelAt(W/2, H/2), corner = pixelAt(4, 4)
        let centerHit = !(center[0] == 14 && center[1] == 18 && center[2] == 28)
        let cornerMiss = corner[0] == 14 && corner[1] == 17 && corner[2] == 28   // 背景色 0.055/0.07/0.11 ×255
        print("  采样中心(\(W/2),\(H/2)) = \(center) \(centerHit ? "✅ 命中场景" : "❌")")
        print("  采样角落(4,4) = \(corner) \(cornerMiss ? "✅ 未命中(背景)" : "❌")")
        print(centerHit && cornerMiss ? "✅ 光线追踪验证通过" : "❌ 验证失败")
    }

    // 显示：把光追结果当纹理画到全屏
    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(renderPipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(resultTexture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

struct QuadVertexLike {
    var position: SIMD4<Float>
    var texCoord: SIMD2<Float>
}

class RaytracerAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 21 · Ray Tracing (MPSRayIntersector)"
        window.center()
        window.contentViewController = RaytracerViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runRaytracer() {
    let app = NSApplication.shared
    let delegate = RaytracerAppDelegate()
    app.delegate = delegate
    app.run()
}
