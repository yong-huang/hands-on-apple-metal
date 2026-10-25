import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// 反应扩散参数。SIMD4 打包避免 Swift/MSL 对齐差异：
// u0 = (F, k, dt, boundary)   F 进食率，k 杀死率，boundary 0=clamp 1=wrap
// u1 = (Du, Dv, 0, 0)         两种物质的扩散速率
struct TuringParams {
    var u0: SIMD4<Float>
    var u1: SIMD4<Float>
}

// 种子参数：u0 = (seed, patchCount, 0, 0)
struct TuringSeedParams {
    var u0: SIMD4<Float>
}

let gridSide = 512
let stepsPerFrame = 10
let defaultF: Float = 0.0370
let defaultK: Float = 0.0600

// 模拟内核：读 A 写 B 的乒乓步进。状态存在 xy 通道（u、v），rgba16float
let turingKernelSource = """
#include <metal_stdlib>
using namespace metal;

struct TuringParams {
    float4 u0;   // F, k, dt, boundary
    float4 u1;   // Du, Dv, 0, 0
};

struct TuringSeedParams {
    float4 u0;   // seed, patchCount, 0, 0
};

float2 stateAt(texture2d<float, access::read> tex, int2 pos, float boundary) {
    int2 size = int2(tex.get_width(), tex.get_height());
    int2 p = boundary > 0.5 ? ((pos % size) + size) % size : clamp(pos, int2(0), size - 1);
    return tex.read(uint2(p)).xy;
}

// 9 点拉普拉斯：正交邻居权重 0.2，对角 0.05，中心 -1——各向异性比 5 点小
float2 laplacian(texture2d<float, access::read> tex, uint2 gid, float boundary) {
    float2 l  = stateAt(tex, int2(gid) + int2(-1, 0), boundary);
    float2 r  = stateAt(tex, int2(gid) + int2( 1, 0), boundary);
    float2 u  = stateAt(tex, int2(gid) + int2( 0,-1), boundary);
    float2 d  = stateAt(tex, int2(gid) + int2( 0, 1), boundary);
    float2 ul = stateAt(tex, int2(gid) + int2(-1,-1), boundary);
    float2 ur = stateAt(tex, int2(gid) + int2( 1,-1), boundary);
    float2 ll = stateAt(tex, int2(gid) + int2(-1, 1), boundary);
    float2 lr = stateAt(tex, int2(gid) + int2( 1, 1), boundary);
    float2 c  = tex.read(gid).xy;
    return -c + (l + r + u + d) * 0.2 + (ul + ur + ll + lr) * 0.05;
}

// Gray-Scott：u 是"食物"，v 是"细胞"——u 被持续补充(F(1-u))、被 v² 消耗；v 吃 u 繁殖、按 (F+k) 死亡
kernel void step_kernel(
    texture2d<float, access::read>  inA  [[texture(0)]],
    texture2d<float, access::write> outB [[texture(1)]],
    constant TuringParams &params [[buffer(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outB.get_width() || gid.y >= outB.get_height()) { return; }
    float F = params.u0.x, k = params.u0.y, dt = params.u0.z, boundary = params.u0.w;
    float Du = params.u1.x, Dv = params.u1.y;

    float2 lap = laplacian(inA, gid, boundary);
    float u = inA.read(gid).x;
    float v = inA.read(gid).y;
    float uvv = u * v * v;

    float u2 = u + (Du * lap.x - uvv + F * (1.0 - u)) * dt;
    float v2 = v + (Dv * lap.y + uvv - (F + k) * v) * dt;
    outB.write(float4(clamp(u2, 0.0, 1.0), clamp(v2, 0.0, 1.0), 0.0, 1.0), gid);
}

// 初始化：u=1 全屏铺满，v 只在若干伪随机小方块里为 1（GPU 直接写，免去 CPU 转 half bits）
kernel void seed_kernel(
    texture2d<float, access::write> outA [[texture(0)]],
    constant TuringSeedParams &sp [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outA.get_width() || gid.y >= outA.get_height()) { return; }
    float seed = sp.u0.x;
    int patchCount = int(sp.u0.y);
    float v = 0.0;
    for (int i = 0; i < patchCount; i++) {
        float3 h = fract(float3(float(i) * 0.1031 + seed, seed * 1.37, float(i) * 0.71 + seed * 2.1) + 0.5);
        h += dot(h, h.yzx + 19.19);
        float2 center = fract(float2(h.x, h.z)) * float(outA.get_width() - 40) + 20;
        float dist = length(float2(gid) - center);
        if (dist < 4.0) { v = 1.0; }
    }
    outA.write(float4(1.0, v, 0.0, 1.0), gid);
}
"""

let turingDrawSource = """
#include <metal_stdlib>
using namespace metal;

struct TuringVertexOut {
    float4 position [[position]];
    float2 uv;
};

struct TuringParams {
    float4 u0;   // F, k, dt, boundary
    float4 u1;   // Du, Dv, 0, 0
};

vertex TuringVertexOut vertex_main(
    const device float2 *positions [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    TuringVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = positions[vid].xy * 0.5 + 0.5;
    return out;
}

fragment float4 fragment_main(
    TuringVertexOut in [[stage_in]],
    texture2d<float> state [[texture(0)]]
) {
    constexpr sampler samp(address::clamp_to_edge, filter::linear);
    float v = state.sample(samp, in.uv).y;

    // v≈0 的背景压成深海军蓝，v 升高经青蓝过渡，花纹核心（v≥0.3）泛白
    float t = smoothstep(0.02, 0.30, v);
    float3 col = mix(float3(0.05, 0.08, 0.18), float3(0.35, 0.75, 0.85), t);
    col = mix(col, float3(0.95, 0.98, 1.00), smoothstep(0.25, 0.38, v));
    return float4(clamp(col, 0.0, 1.0), 1.0);
}
"""

let turingQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

func makeTuringLibrary(source: String, device: MTLDevice) -> MTLLibrary {
    try! device.makeLibrary(source: source, options: nil)
}

func makeSimTextures(device: MTLDevice) -> (MTLTexture, MTLTexture) {
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: gridSide, height: gridSide, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    return (device.makeTexture(descriptor: desc)!, device.makeTexture(descriptor: desc)!)
}

func runSeedPass(device: MTLDevice, queue: MTLCommandQueue, texA: MTLTexture, seed: Float, patchCount: Int) {
    let library = makeTuringLibrary(source: turingKernelSource, device: device)
    guard let fn = library.makeFunction(name: "seed_kernel") else { fatalError("seed_kernel 缺失") }
    let ps = try! device.makeComputePipelineState(function: fn)
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(ps)
    enc.setTexture(texA, index: 0)
    var sp = TuringSeedParams(u0: SIMD4(seed, Float(patchCount), 0, 0))
    enc.setBytes(&sp, length: MemoryLayout<TuringSeedParams>.stride, index: 1)
    let w = ps.threadExecutionWidth
    let h = ps.maxTotalThreadsPerThreadgroup / w
    enc.dispatchThreadgroups(MTLSize(width: (gridSide + w - 1) / w, height: (gridSide + h - 1) / h, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
}

// 编码一步乒乓（可复用于窗口模式与 bench/export）
func encodeStep(encoder: MTLComputeCommandEncoder, ps: MTLComputePipelineState, inA: MTLTexture, outB: MTLTexture, params: inout TuringParams) {
    encoder.setComputePipelineState(ps)
    encoder.setTexture(inA, index: 0)
    encoder.setTexture(outB, index: 1)
    encoder.setBytes(&params, length: MemoryLayout<TuringParams>.stride, index: 2)
    let w = ps.threadExecutionWidth
    let h = ps.maxTotalThreadsPerThreadgroup / w
    encoder.dispatchThreadgroups(MTLSize(width: (gridSide + w - 1) / w, height: (gridSide + h - 1) / h, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
}

func describeParams(f: Float, k: Float, boundary: Bool) -> String {
    String(format: "参数：F %.4f k %.4f 边界 %@（←/→ 调 F，↑/↓ 调 k，B 切边界，R 重播）", f, k, boundary ? "wrap" : "clamp")
}

// MARK: - 窗口模式

class TuringViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var stepPS: MTLComputePipelineState!
    var drawPS: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var texA: MTLTexture!
    var texB: MTLTexture!
    var flip = false
    var f = defaultF
    var k = defaultK
    var wrapBoundary = false
    var seed: Float = 1.0

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = TuringView(frame: NSRect(x: 0, y: 0, width: 512, height: 512), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? TuringView)?.controller = self
        queue = device.makeCommandQueue()
        let lib = makeTuringLibrary(source: turingKernelSource, device: device)
        stepPS = try! device.makeComputePipelineState(function: lib.makeFunction(name: "step_kernel")!)
        let drawLib = makeTuringLibrary(source: turingDrawSource, device: device)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = drawLib.makeFunction(name: "vertex_main")
        desc.fragmentFunction = drawLib.makeFunction(name: "fragment_main")
        desc.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        drawPS = try! device.makeRenderPipelineState(descriptor: desc)
        vertexBuffer = device.makeBuffer(bytes: turingQuad, length: turingQuad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        (texA, texB) = makeSimTextures(device: device)
        reset()
        print("Device: \(device.name)")
        print(describeParams(f: f, k: k, boundary: wrapBoundary))
        print("[Simulation ready] \(gridSide)×\(gridSide) · compute 乒乓 · 每帧 \(stepsPerFrame) 步")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    func reset() {
        runSeedPass(device: device, queue: queue, texA: texA, seed: seed, patchCount: 8)
        flip = false
    }

    func currentParams() -> TuringParams {
        TuringParams(u0: SIMD4(f, k, 1.0, wrapBoundary ? 1 : 0), u1: SIMD4(0.16, 0.08, 0, 0))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer() else { return }
        // 同一命令缓冲同时只允许一个活跃 encoder：先编码全部 compute 步，结束后再建 render encoder
        let computeEnc = cb.makeComputeCommandEncoder()!
        for _ in 0..<stepsPerFrame {
            let (inA, outB) = flip ? (texB!, texA!) : (texA!, texB!)
            var p = currentParams()
            encodeStep(encoder: computeEnc, ps: stepPS, inA: inA, outB: outB, params: &p)
            flip.toggle()
        }
        computeEnc.endEncoding()
        let drawEnc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        drawEnc.setRenderPipelineState(drawPS)
        drawEnc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        drawEnc.setFragmentTexture(flip ? texA : texB, index: 0)
        drawEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: turingQuad.count)
        drawEnc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

class TuringView: MTKView {
    weak var controller: TuringViewController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123: c.f = max(0.010, c.f - 0.001)          // ←
        case 124: c.f = min(0.090, c.f + 0.001)          // →
        case 125: c.k = min(0.070, c.k + 0.001)          // ↓
        case 126: c.k = max(0.030, c.k - 0.001)          // ↑
        case 11:                                          // B
            c.wrapBoundary.toggle()
        case 15:                                          // R
            c.seed += 1.0
            c.reset()
            print("重播：seed \(c.seed)")
        default:
            return super.keyDown(with: event)
        }
        print(describeParams(f: c.f, k: c.k, boundary: c.wrapBoundary))
    }
}

class TuringAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: TuringViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 512, height: 512),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "图灵花纹 Gray-Scott（←→ 调 F · ↑↓ 调 k · B 切边界 · R 重播）"
        window.center()
        controller = TuringViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - bench 与离屏导出

// 验收基准：跑 1000 步纯 compute 计时（单命令缓冲编码 1000 次 dispatch）
func benchTuring(device: MTLDevice, queue: MTLCommandQueue) {
    let lib = makeTuringLibrary(source: turingKernelSource, device: device)
    let ps = try! device.makeComputePipelineState(function: lib.makeFunction(name: "step_kernel")!)
    let (texA, texB) = makeSimTextures(device: device)
    var params = TuringParams(u0: SIMD4(defaultF, defaultK, 1.0, 0), u1: SIMD4(0.16, 0.08, 0, 0))
    runSeedPass(device: device, queue: queue, texA: texA, seed: 1.0, patchCount: 8)

    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    var flip = false
    for _ in 0..<1000 {
        let (inA, outB) = flip ? (texB, texA) : (texA, texB)
        encodeStep(encoder: enc, ps: ps, inA: inA, outB: outB, params: &params)
        flip.toggle()
    }
    enc.endEncoding()
    let t0 = CFAbsoluteTimeGetCurrent()
    cb.commit()
    cb.waitUntilCompleted()
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    print(String(format: "1000 步（512×512，每步 1 次 9 点拉普拉斯全网格 dispatch）耗时 %.1f ms（每步 %.0f µs）", ms, ms))
    print(ms < 1000 ? "✅ 验收线 1000 ms：通过" : "❌ 未达验收线 1000 ms")
}

// 离屏导出：seed → 跑 steps 步 → 画进 rgba8 纹理 → PNG
func exportTuringPNG(path: String, f: Float, k: Float, seed: Float, steps: Int, boundary: Float = 0, width: Int = 1024, height: Int = 1024) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let lib = makeTuringLibrary(source: turingKernelSource, device: device)
    let ps = try! device.makeComputePipelineState(function: lib.makeFunction(name: "step_kernel")!)
    let (texA, texB) = makeSimTextures(device: device)
    runSeedPass(device: device, queue: queue, texA: texA, seed: seed, patchCount: 8)
    var params = TuringParams(u0: SIMD4(f, k, 1.0, boundary), u1: SIMD4(0.16, 0.08, 0, 0))

    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    var flip = false
    for _ in 0..<steps {
        let (inA, outB) = flip ? (texB, texA) : (texA, texB)
        encodeStep(encoder: enc, ps: ps, inA: inA, outB: outB, params: &params)
        flip.toggle()
    }
    enc.endEncoding()

    // 渲染进离屏 rgba8 纹理
    let drawLib = makeTuringLibrary(source: turingDrawSource, device: device)
    let rpd2 = MTLRenderPipelineDescriptor()
    rpd2.vertexFunction = drawLib.makeFunction(name: "vertex_main")
    rpd2.fragmentFunction = drawLib.makeFunction(name: "fragment_main")
    rpd2.colorAttachments[0].pixelFormat = .rgba8Unorm
    let drawPS = try! device.makeRenderPipelineState(descriptor: rpd2)
    let vertexBuffer = device.makeBuffer(bytes: turingQuad, length: turingQuad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
    let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    texDesc.usage = [.renderTarget, .shaderRead]
    let outTex = device.makeTexture(descriptor: texDesc)!
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = outTex
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    let drawEnc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    drawEnc.setRenderPipelineState(drawPS)
    drawEnc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    drawEnc.setFragmentTexture(flip ? texA : texB, index: 0)
    drawEnc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: turingQuad.count)
    drawEnc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    outTex.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = ctx.makeImage()!
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("PNG 写出失败：\(path)")
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    print(String(format: "F %.4f k %.4f seed %.0f 步数 %d 边界 %@ → %@", f, k, seed, steps, boundary > 0.5 ? "wrap" : "clamp", path))
    print("✅ PNG 已写出（\(size) 字节）")
}

func runTuring() {
    let args = CommandLine.arguments

    // bench 模式：1000 步纯 compute 计时
    if args.contains("bench") {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("本机不支持 Metal")
        }
        print("Device: \(device.name)")
        benchTuring(device: device, queue: queue)
        exit(0)
    }

    // export 模式：turing export out.png [F k seed steps boundary(0=clamp 1=wrap)]
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        let path = args[i + 1]
        let f = args.count > i + 2 ? Float(args[i + 2]) ?? defaultF : defaultF
        let k = args.count > i + 3 ? Float(args[i + 3]) ?? defaultK : defaultK
        let seed = args.count > i + 4 ? Float(args[i + 4]) ?? 1.0 : 1.0
        let steps = args.count > i + 5 ? Int(args[i + 5]) ?? 15000 : 15000
        let boundary = args.count > i + 6 ? Float(args[i + 6]) ?? 0 : 0
        exportTuringPNG(path: path, f: f, k: k, seed: seed, steps: steps, boundary: boundary)
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = TuringAppDelegate()
    app.delegate = delegate
    app.run()
}
