// 14 · GPU 图像滤镜：Compute Kernel 灰度转换
// 亮点：MTLTexture 第一次作为"计算的输出"——kernel 逐像素读写纹理，
// CPU 端回读结果做 R==G==B 验证，把"算得对不对"钉死。
import Cocoa
import Metal
import MetalKit

// 全屏四边形顶点：位置(NDC) + 纹理坐标
struct QuadVertex {
    var position: SIMD4<Float>
    var texCoord: SIMD2<Float>
}

class GrayscaleViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var computePipeline: MTLComputePipelineState!
    var renderPipeline: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var srcTexture: MTLTexture!     // 彩色原图（CPU 生成）
    var dstTexture: MTLTexture!     // 灰度结果（compute 写入）
    let W = 512, H = 512

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct QuadVertex {
        float4 position;
        float2 texCoord;
    };
    struct RasterizerData {
        float4 position [[position]];
        float2 texCoord;
    };

    // —— 计算侧：一个线程负责一个像素 ——
    kernel void grayscale_kernel(
        texture2d<float, access::read>  src   [[texture(0)]],
        texture2d<float, access::write> dst   [[texture(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= src.get_width() || gid.y >= src.get_height()) { return; }
        float4 c = src.read(gid);
        // 亮度加权：人眼对绿色最敏感，不能简单平均
        float y = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
        dst.write(float4(y, y, y, 1.0), gid);
    }

    // —— 渲染侧：全屏四边形把结果纹理画出来 ——
    vertex RasterizerData vertex_main(
        device const QuadVertex *verts [[buffer(0)]],
        uint vid [[vertex_id]])
    {
        RasterizerData out;
        out.position = verts[vid].position;
        out.texCoord = verts[vid].texCoord;
        return out;
    }

    fragment float4 fragment_main(
        RasterizerData in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler samp [[sampler(0)]])
    {
        return tex.sample(samp, in.texCoord);
    }
    """

    // CPU 生成彩色测试图：色相渐变 + 三条竖色带（灰度后能看出层次差异）
    func makeTestImage() -> [UInt8] {
        var px = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let i = (y * W + x) * 4
                if x > W / 3 && x < W * 2 / 3 {          // 中间竖带：品红
                    px[i] = 220; px[i+1] = 30; px[i+2] = 140
                } else if x > W * 5 / 6 {                 // 右侧竖带：青
                    px[i] = 30; px[i+1] = 190; px[i+2] = 200
                } else {                                   // 其余：绿→紫渐变
                    let t = Float(x + y) / Float(W + H)
                    px[i]   = UInt8(60 + 160 * t)
                    px[i+1] = UInt8(200 - 140 * t)
                    px[i+2] = UInt8(90 + 120 * t)
                }
                px[i+3] = 255
            }
        }
        return px
    }

    func makeTexture(from px: [UInt8], usage: MTLTextureUsage) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: W, height: H, mipmapped: false)
        desc.usage = usage
        desc.storageMode = .shared          // 统一内存：CPU 既能灌入也能回读
        let tex = device.makeTexture(descriptor: desc)!
        if !px.isEmpty {
            tex.replace(region: MTLRegionMake2D(0, 0, W, H),
                        mipmapLevel: 0, withBytes: px, bytesPerRow: W * 4)
        }
        return tex
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
            computePipeline = try device.makeComputePipelineState(
                function: library.makeFunction(name: "grayscale_kernel")!)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vertex_main")
            desc.fragmentFunction = library.makeFunction(name: "fragment_main")
            desc.colorAttachments[0].pixelFormat = v.colorPixelFormat
            renderPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("管线创建失败: \(error)"); exit(1)
        }

        // 全屏四边形：两个三角形，位置 NDC + uv
        let quad: [QuadVertex] = [
            QuadVertex(position: SIMD4(-1, -1, 0, 1), texCoord: SIMD2(0, 1)),
            QuadVertex(position: SIMD4( 1, -1, 0, 1), texCoord: SIMD2(1, 1)),
            QuadVertex(position: SIMD4(-1,  1, 0, 1), texCoord: SIMD2(0, 0)),
            QuadVertex(position: SIMD4( 1,  1, 0, 1), texCoord: SIMD2(1, 0)),
        ]
        // TriangleStrip 只需要 4 顶点（实验 04 的技巧）
        vertexBuffer = device.makeBuffer(bytes: quad, length: quad.count * MemoryLayout<QuadVertex>.stride)
        srcTexture = makeTexture(from: makeTestImage(), usage: [.shaderRead])
        dstTexture = makeTexture(from: [], usage: [.shaderRead, .shaderWrite])
        print("测试图 \(W)×\(H) rgba8Unorm 已生成；compute 管线就绪")
        runGrayscaleOnce()
    }

    // 独立执行一次 compute（渲染循环开始前），并做 CPU 回读验证
    func runGrayscaleOnce() {
        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(computePipeline)
        enc.setTexture(srcTexture, index: 0)
        enc.setTexture(dstTexture, index: 1)
        // 派发 512×512 线程：32×32 的组，16×16 组
        let group = MTLSize(width: 32, height: 32, depth: 1)
        let groups = MTLSize(width: (W + 31) / 32, height: (H + 31) / 32, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        // CPU 回读：抽 5 个采样点验证 R==G==B（灰度的定义）
        var px = [UInt8](repeating: 0, count: W * 4)
        var ok = true
        for (n, (x, y)) in [(10, 10), (256, 256), (500, 500), (256, 60), (60, 480)].enumerated() {
            dstTexture.getBytes(&px, bytesPerRow: W * 4,
                                from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            let (r, g, b) = (px[0], px[1], px[2])
            let gray = abs(Int(r) - Int(g)) <= 1 && abs(Int(g) - Int(b)) <= 1
            ok = ok && gray
            print("  采样\(n) (\(x),\(y)) → R=\(r) G=\(g) B=\(b) \(gray ? "✅" : "❌")")
        }
        print(ok ? "✅ 灰度转换验证通过：所有采样点 R=G=B" : "❌ 灰度验证失败")
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(dstTexture, index: 0)     // 画的是 compute 的输出
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

class GrayscaleAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 14 · Compute Grayscale"
        window.center()
        window.contentViewController = GrayscaleViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runGrayscale() {
    let app = NSApplication.shared
    let delegate = GrayscaleAppDelegate()
    app.delegate = delegate
    app.run()
}
