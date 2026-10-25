import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let gridSide = 1024

// 播种参数。SIMD4 打包避免 Swift/MSL 对齐差异：
// u0 = (mode, density, cx, cy)  mode 0=随机 1=清空 2=Glider(cx,cy=左上角) 3=画笔
struct GolSeedParams {
    var u0: SIMD4<Float>
}

// 步进内核：Conway 生命游戏 B3/S23。状态存 r8Unorm 的 r 通道（0/1）
let golKernelSource = """
#include <metal_stdlib>
using namespace metal;

struct GolSeedParams {
    float4 u0;   // mode, density, cx, cy
};

// 随机填充（mode 0，density 为活细胞比例）/ 清空（mode 1）/ 画 Glider（mode 2）/ 画笔（mode 3，圆刷）
kernel void seed_kernel(
    texture2d<float, access::write> out [[texture(0)]],
    constant GolSeedParams &sp [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
    int mode = int(sp.u0.x);
    float v = 0.0;
    if (mode == 0) {
        float3 h = fract(float3(float(gid.x), float(gid.y), sp.u0.y) * 0.1031);
        h += dot(h, h.yzx + 33.33);
        v = fract(h.x) < sp.u0.y ? 1.0 : 0.0;   // density 混用作随机阈值
    } else if (mode == 2) {
        // Glider（向右下平移的经典构型）：相对 (cx,cy) 的 5 个活细胞
        int2 g = int2(gid) - int2(sp.u0.zw);
        bool alive = all(g == int2(1, 0)) || all(g == int2(2, 1)) ||
                     all(g == int2(0, 2)) || all(g == int2(1, 2)) || all(g == int2(2, 2));
        v = alive ? 1.0 : 0.0;
    } else if (mode == 3) {
        float2 d = float2(gid) - sp.u0.zw;
        v = length(d) < 4.0 ? 1.0 : 0.0;
    }
    out.write(float4(v, v, v, 1.0), gid);
}

// 步进：8 邻居求和 + B3/S23 规则。环面边界——坐标用 int 运算取模，避免 uint 下溢
kernel void step_kernel(
    texture2d<float, access::read>  inA  [[texture(0)]],
    texture2d<float, access::write> outB [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outB.get_width() || gid.y >= outB.get_height()) { return; }
    int2 size = int2(outB.get_width(), outB.get_height());
    int n = 0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            if (dx == 0 && dy == 0) { continue; }
            int2 p = (int2(gid) + int2(dx, dy) + size) % size;
            n += inA.read(uint2(p)).r > 0.5 ? 1 : 0;
        }
    }
    float alive = inA.read(gid).r > 0.5 ? 1.0 : 0.0;
    float next = (n == 3) || (alive > 0.5 && n == 2) ? 1.0 : 0.0;   // B3/S23
    outB.write(float4(next, next, next, 1.0), gid);
}
"""

let golDrawSource = """
#include <metal_stdlib>
using namespace metal;

struct GolVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex GolVertexOut vertex_main(
    const device float2 *positions [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    GolVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = positions[vid].xy * 0.5 + 0.5;
    return out;
}

fragment float4 fragment_main(
    GolVertexOut in [[stage_in]],
    texture2d<float> state [[texture(0)]]
) {
    constexpr sampler samp(address::repeat, filter::nearest);
    float alive = state.sample(samp, in.uv).r;
    float3 col = mix(float3(0.05, 0.07, 0.10), float3(0.45, 0.90, 0.60), alive);
    return float4(col, 1.0);
}
"""

let golQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

func makeGolPipeline(device: MTLDevice, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let library = try! device.makeLibrary(source: golDrawSource, options: nil)
    guard let vf = library.makeFunction(name: "vertex_main"),
          let ff = library.makeFunction(name: "fragment_main") else {
        fatalError("着色器函数缺失：vertex_main / fragment_main")
    }
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vf
    desc.fragmentFunction = ff
    desc.colorAttachments[0].pixelFormat = colorFormat
    return try! device.makeRenderPipelineState(descriptor: desc)
}

func makeGolTextures(device: MTLDevice) -> (MTLTexture, MTLTexture) {
    let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: gridSide, height: gridSide, mipmapped: false)
    desc.usage = [.shaderRead, .shaderWrite]
    return (device.makeTexture(descriptor: desc)!, device.makeTexture(descriptor: desc)!)
}

func makeGolStepPS(device: MTLDevice) -> MTLComputePipelineState {
    let library = try! device.makeLibrary(source: golKernelSource, options: nil)
    return try! device.makeComputePipelineState(function: library.makeFunction(name: "step_kernel")!)
}

func makeGolSeedPS(device: MTLDevice) -> MTLComputePipelineState {
    let library = try! device.makeLibrary(source: golKernelSource, options: nil)
    return try! device.makeComputePipelineState(function: library.makeFunction(name: "seed_kernel")!)
}

func golSeed(queue: MTLCommandQueue, ps: MTLComputePipelineState, tex: MTLTexture, mode: Float, density: Float, cx: Float = 0, cy: Float = 0) {
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(ps)
    enc.setTexture(tex, index: 0)
    var sp = GolSeedParams(u0: SIMD4(mode, density, cx, cy))
    enc.setBytes(&sp, length: MemoryLayout<GolSeedParams>.stride, index: 1)
    let w = ps.threadExecutionWidth
    let h = ps.maxTotalThreadsPerThreadgroup / w
    enc.dispatchThreadgroups(MTLSize(width: (gridSide + w - 1) / w, height: (gridSide + h - 1) / h, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
}

func golStep(queue: MTLCommandQueue, ps: MTLComputePipelineState, inA: MTLTexture, outB: MTLTexture) {
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(ps)
    enc.setTexture(inA, index: 0)
    enc.setTexture(outB, index: 1)
    let w = ps.threadExecutionWidth
    let h = ps.maxTotalThreadsPerThreadgroup / w
    enc.dispatchThreadgroups(MTLSize(width: (gridSide + w - 1) / w, height: (gridSide + h - 1) / h, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
}

// MARK: - 窗口模式（点击/拖拽播种 · 空格暂停 · R 随机重置 · 标题栏 FPS）

class GolViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var stepPS: MTLComputePipelineState!
    var seedPS: MTLComputePipelineState!
    var drawPS: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var texA: MTLTexture!
    var texB: MTLTexture!
    var flip = false
    var paused = false
    var generation = 0

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = GolView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? GolView)?.controller = self
        queue = device.makeCommandQueue()
        stepPS = makeGolStepPS(device: device)
        seedPS = makeGolSeedPS(device: device)
        drawPS = makeGolPipeline(device: device, colorFormat: metalView.colorPixelFormat)
        vertexBuffer = device.makeBuffer(bytes: golQuad, length: golQuad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        (texA, texB) = makeGolTextures(device: device)
        randomReset()
        print("Device: \(device.name)")
        print("网格：\(gridSide)×\(gridSide) · 点击/拖拽播种 · 空格暂停 · R 随机汤 · C 清空后手画构型")
        print("[Pipeline ready] compute 乒乓 + fragment 呈现 · 帧率见标题栏")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    func randomReset() {
        golSeed(queue: queue, ps: seedPS, tex: texA, mode: 0, density: 0.28)
        flip = false
        generation = 0
    }

    func clearBoard() {
        golSeed(queue: queue, ps: seedPS, tex: texA, mode: 1, density: 0)
        flip = false
        generation = 0
    }

    func brush(at point: SIMD2<Float>) {
        golSeed(queue: queue, ps: seedPS, tex: flip ? texB : texA, mode: 3, density: 0, cx: point.x, cy: point.y)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        if !paused {
            let (inA, outB) = flip ? (texB!, texA!) : (texA!, texB!)
            golStep(queue: queue, ps: stepPS, inA: inA, outB: outB)
            flip.toggle()
            generation += 1
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(drawPS)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(flip ? texA : texB, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: golQuad.count)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        if generation % 120 == 0 {
            let state = paused ? "已暂停（第 \(generation) 代）" : "第 \(generation) 代"
            view.window?.title = "GPU 生命游戏 · \(state) · FPS 见标题栏"
            print(paused ? "已暂停于第 \(generation) 代" : "第 \(generation) 代")
        }
    }
}

class GolView: MTKView {
    weak var controller: GolViewController?
    var mouseIsDown = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseIsDown = true
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        let b = bounds
        c.brush(at: SIMD2(Float(p.x / b.width), Float(1 - p.y / b.height)))
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseIsDown, let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        let b = bounds
        c.brush(at: SIMD2(Float(p.x / b.width), Float(1 - p.y / b.height)))
    }

    override func mouseUp(with event: NSEvent) {
        mouseIsDown = false
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return super.keyDown(with: event) }
        if event.keyCode == 49 {                    // 空格
            c.paused.toggle()
            print(c.paused ? "已暂停" : "继续运行")
        } else if event.keyCode == 15 {             // R
            c.randomReset()
            print("随机重置（28% 密度随机汤）")
        } else if event.keyCode == 8 {              // C
            c.clearBoard()
            print("棋盘已清空——用鼠标画上你想要的初始构型")
        } else {
            super.keyDown(with: event)
        }
    }
}

class GolAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: GolViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "GPU 生命游戏 · 点击播种 空格暂停 R随机 C清空手画"
        window.center()
        controller = GolViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - bench（1024² 步进计时）与 test（Glider 100 代验收）

func golBench(device: MTLDevice, queue: MTLCommandQueue) {
    let stepPS = makeGolStepPS(device: device)
    let seedPS = makeGolSeedPS(device: device)
    let (texA, texB) = makeGolTextures(device: device)
    golSeed(queue: queue, ps: seedPS, tex: texA, mode: 0, density: 0.28)

    var flip = false
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<100 {
        let (inA, outB) = flip ? (texB, texA) : (texA, texB)
        golStep(queue: queue, ps: stepPS, inA: inA, outB: outB)
        flip.toggle()
    }
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    print(String(format: "1024×1024 跑 100 代耗时 %.1f ms（每代 %.2f ms，含每代一次命令缓冲提交）", ms, ms / 100))
    print(ms / 100 < 16.6 ? "✅ 单代预算 16.6 ms（60 FPS）：通过" : "❌ 未达 60 FPS 预算")
}

// 验收：左上角 (10,10) 播一枚 Glider，跑 100 代后应整体向右下平移 25 格（周期 4、每周期移 1 格）
func golGliderTest(device: MTLDevice, queue: MTLCommandQueue) {
    let stepPS = makeGolStepPS(device: device)
    let seedPS = makeGolSeedPS(device: device)
    let (texA, texB) = makeGolTextures(device: device)
    golSeed(queue: queue, ps: seedPS, tex: texA, mode: 1, density: 0)          // 清空
    golSeed(queue: queue, ps: seedPS, tex: texA, mode: 2, density: 0, cx: 10, cy: 10)   // 放置 Glider

    var flip = false
    for _ in 0..<100 {
        let (inA, outB) = flip ? (texB, texA) : (texA, texB)
        golStep(queue: queue, ps: stepPS, inA: inA, outB: outB)
        flip.toggle()
    }

    // 回读终态，求活细胞包围盒
    let state = flip ? texA : texB
    var pixels = [UInt8](repeating: 0, count: gridSide * gridSide)
    state.getBytes(&pixels, bytesPerRow: gridSide, from: MTLRegionMake2D(0, 0, gridSide, gridSide), mipmapLevel: 0)
    var minX = gridSide, minY = gridSide, maxX = -1, maxY = -1, count = 0
    for y in 0..<gridSide {
        for x in 0..<gridSide {
            if pixels[y * gridSide + x] > 127 {
                count += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    print("100 代后：活细胞 \(count) 个，包围盒 (\(minX),\(minY))–(\(maxX),\(maxY))")
    let ok = count == 5 && minX == 35 && minY == 35 && maxX == 37 && maxY == 37
    print(ok ? "✅ Glider 每 4 代右下平移 1 格：100 代后包围盒恰为 (35,35)–(37,37)，通过" : "❌ 包围盒与预期 (35,35)–(37,37) 不符")
}

// MARK: - 离屏导出（固定 seed 演化 N 代后写 PNG）

func exportGolPNG(path: String, seed: Float, generations: Int, width: Int = 1024, height: Int = 1024) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let stepPS = makeGolStepPS(device: device)
    let seedPS = makeGolSeedPS(device: device)
    let drawPS = makeGolPipeline(device: device, colorFormat: .rgba8Unorm)
    let (texA, texB) = makeGolTextures(device: device)
    golSeed(queue: queue, ps: seedPS, tex: texA, mode: 0, density: 0.28, cx: seed)

    var flip = false
    for _ in 0..<generations {
        let (inA, outB) = flip ? (texB, texA) : (texA, texB)
        golStep(queue: queue, ps: stepPS, inA: inA, outB: outB)
        flip.toggle()
    }

    let vertexBuffer = device.makeBuffer(bytes: golQuad, length: golQuad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
    let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    texDesc.usage = [.renderTarget, .shaderRead]
    let outTex = device.makeTexture(descriptor: texDesc)!
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = outTex
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    enc.setRenderPipelineState(drawPS)
    enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    enc.setFragmentTexture(flip ? texA : texB, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: golQuad.count)
    enc.endEncoding()
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
    print("seed \(seed)  演化 \(generations) 代  尺寸 \(width)×\(height)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runGol() {
    let args = CommandLine.arguments

    if args.contains("bench") {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("本机不支持 Metal")
        }
        print("Device: \(device.name)")
        golBench(device: device, queue: queue)
        exit(0)
    }

    if args.contains("test") {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            fatalError("本机不支持 Metal")
        }
        print("Device: \(device.name)")
        golGliderTest(device: device, queue: queue)
        exit(0)
    }

    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        let path = args[i + 1]
        let seed = args.count > i + 2 ? (Float(args[i + 2]) ?? 1.0) : 1.0
        let gens = args.count > i + 3 ? (Int(args[i + 3]) ?? 200) : 200
        exportGolPNG(path: path, seed: seed, generations: gens)
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = GolAppDelegate()
    app.delegate = delegate
    app.run()
}
