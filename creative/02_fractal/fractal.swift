import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// 每帧传给片元着色器的 uniforms。为避免 Swift/MSL 对齐差异，全部用 SIMD4 打包：
// u0 = (center.x, center.y, scale, maxIter)  scale = 纵向覆盖的复平面高度
// u1 = (juliaC.x, juliaC.y, mode(0=Mandelbrot 1=Julia), aspect = 宽/高)
struct FractalUniforms {
    var u0: SIMD4<Float>
    var u1: SIMD4<Float>
}

let fractalVertexSource = """
#include <metal_stdlib>
using namespace metal;

struct FractalVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex FractalVertexOut vertex_main(
    const device float2 *positions [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    FractalVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = positions[vid].xy * 0.5 + 0.5;
    return out;
}
"""

let fractalFragmentSource = """
#include <metal_stdlib>
using namespace metal;

struct FractalUniforms {
    float4 u0;   // center.x, center.y, scale, maxIter
    float4 u1;   // juliaC.x, juliaC.y, mode, aspect
};

float3 pal(float t) {
    // 经典 IQ 调色板：蓝-橙主调，随 t 循环
    float3 a = float3(0.5, 0.5, 0.5);
    float3 b = float3(0.5, 0.5, 0.5);
    float3 c = float3(1.0, 1.0, 1.0);
    float3 d = float3(0.0, 0.10, 0.20);
    return a + b * cos(6.28318 * (c * t + d));
}

fragment float4 fragment_main(
    FractalVertexOut in [[stage_in]],
    constant FractalUniforms &u [[buffer(1)]]
) {
    float2 center = u.u0.xy;
    float scale = u.u0.z;
    int maxIter = int(u.u0.w);
    uint mode = uint(u.u1.z);
    float aspect = u.u1.w;
    float2 jc = u.u1.xy;

    // 像素 → 复平面：纵向覆盖 scale，横向按宽高比展开（texCoord y 随屏幕向上增长，与虚部同向）
    float2 coord = (in.texCoord - 0.5) * float2(aspect, 1.0) * scale + center;

    // 逃逸时间迭代：Mandelbrot 是"每个点当 c 试"，Julia 是"每个点当 z0 试"
    float2 z, c;
    if (mode == 0) { z = float2(0.0, 0.0); c = coord; }
    else           { z = coord;            c = jc;   }

    float sn = -1.0;                       // 平滑迭代计数；-1 表示未逃逸（集合内部）
    float2 v = z;
    for (int i = 0; i < 4096; i++) {
        if (i >= maxIter) { break; }
        v = float2(v.x * v.x - v.y * v.y, 2.0 * v.x * v.y) + c;
        float d2 = dot(v, v);
        if (d2 > 256.0) {
            sn = float(i) - log2(log2(d2)) + 4.0;   // 平滑化：消除整数迭代同心条纹
            break;
        }
    }

    if (sn < 0.0) { return float4(0.0, 0.0, 0.0, 1.0); }   // 集合内部：黑
    // 归一化 + 幂次展开：低迭代数的外场占满大半调色板，边界附近快速收尾一圈
    float t = pow(sn / float(maxIter), 0.35);
    return float4(clamp(pal(t), 0.0, 1.0), 1.0);
}
"""

let fractalQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

func makeFractalLibraryAndFunctions(device: MTLDevice) -> (MTLLibrary, MTLFunction, MTLFunction) {
    let library = try! device.makeLibrary(source: fractalVertexSource + "\n" + fractalFragmentSource, options: nil)
    guard let vf = library.makeFunction(name: "vertex_main"),
          let ff = library.makeFunction(name: "fragment_main") else {
        fatalError("着色器函数缺失：vertex_main / fragment_main")
    }
    return (library, vf, ff)
}

func makeFractalPipeline(device: MTLDevice, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let (_, vf, ff) = makeFractalLibraryAndFunctions(device: device)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vf
    desc.fragmentFunction = ff
    desc.colorAttachments[0].pixelFormat = colorFormat
    return try! device.makeRenderPipelineState(descriptor: desc)
}

// 视图状态：复平面窗口。初始 Mandelbrot 全景；缩放下限受 float 精度约束（见 README）
struct FractalViewState {
    var center = SIMD2<Float>(-0.6, 0.0)
    var scale: Float = 2.5
    var mode = 0                    // 0 = Mandelbrot，1 = Julia
    var juliaC = SIMD2<Float>(0, 0)
    let aspect: Float

    init(aspect: Float) { self.aspect = aspect }

    var maxIter: UInt32 {
        let depth = max(0.0, log2(2.5 / scale))
        return UInt32(min(1500, 128 + Int(24 * depth)))
    }

    var uniforms: FractalUniforms {
        FractalUniforms(
            u0: SIMD4(center.x, center.y, scale, Float(maxIter)),
            u1: SIMD4(juliaC.x, juliaC.y, Float(mode), aspect)
        )
    }

    // 视口内一点（0~1，y 向上）对应的复数
    func complex(at texCoord: SIMD2<Float>) -> SIMD2<Float> {
        return (texCoord - SIMD2(0.5, 0.5)) * SIMD2(aspect, 1.0) * scale + center
    }

    mutating func zoom(factor: Float, around texCoord: SIMD2<Float>) {
        let anchor = complex(at: texCoord)
        scale = min(8.0, max(4.0e-5, scale * factor))
        // 缩放后把锚点拉回原视口位置，实现"以光标为中心缩放"
        center = anchor - (texCoord - SIMD2(0.5, 0.5)) * SIMD2(aspect, 1.0) * scale
    }

    mutating func pan(deltaTexCoord: SIMD2<Float>) {
        center -= deltaTexCoord * SIMD2(aspect, 1.0) * scale
    }
}

func describeState(_ s: FractalViewState) -> String {
    let modeName = s.mode == 0 ? "Mandelbrot" : "Julia c=(\(String(format: "%.4f", s.juliaC.x)), \(String(format: "%.4f", s.juliaC.y)))"
    return String(format: "模式：%@ 中心 (%.4f, %.4f) 纵向覆盖 %.2e maxIter %d", modeName, s.center.x, s.center.y, s.scale, s.maxIter)
}

func pixelFormatName(_ f: MTLPixelFormat) -> String {
    switch f {
    case .bgra8Unorm: return "bgra8Unorm"
    case .rgba8Unorm: return "rgba8Unorm"
    default: return "raw(\(f.rawValue))"
    }
}

// MARK: - 窗口模式

class FractalViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var state = FractalViewState(aspect: 800.0 / 600.0)

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = FractalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? FractalView)?.controller = self
        commandQueue = device.makeCommandQueue()
        pipelineState = makeFractalPipeline(device: device, colorFormat: metalView.colorPixelFormat)
        vertexBuffer = device.makeBuffer(
            bytes: fractalQuad,
            length: fractalQuad.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        )
        print("Device: \(device.name)")
        print(describeState(state))
        print("[Pipeline ready] vertex_main + fragment_main（\(pixelFormatName(metalView.colorPixelFormat))）")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        var u = state.uniforms
        enc.setFragmentBytes(&u, length: MemoryLayout<FractalUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fractalQuad.count)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    // 交互更新后调用：打印状态并触发重绘（MTKView 默认按需绘制）
    func stateChanged() {
        print(describeState(state))
        metalView.needsDisplay = true
    }
}

class FractalView: MTKView {
    weak var controller: FractalViewController?
    var mouseDownLocation: NSPoint?
    var dragLastLocation: NSPoint?
    var dragDistance: CGFloat = 0

    override var acceptsFirstResponder: Bool { true }

    // 事件坐标 → texCoord（0~1，y 向上；与 NSView 底左原点一致）
    func texCoord(at point: NSPoint) -> SIMD2<Float> {
        let b = bounds
        return SIMD2(Float(point.x / b.width), Float(point.y / b.height))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller else { return super.scrollWheel(with: event) }
        let factor = pow(1.25, Float(-event.deltaY))   // 滚上放大、滚下缩小
        guard factor != 1.0 else { return }
        controller.state.zoom(factor: factor, around: texCoord(at: convert(event.locationInWindow, from: nil)))
        controller.stateChanged()
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        dragLastLocation = mouseDownLocation
        dragDistance = 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard let controller, let last = dragLastLocation else { return }
        let now = convert(event.locationInWindow, from: nil)
        let dx = (now.x - last.x) / bounds.width
        let dy = (now.y - last.y) / bounds.height
        dragDistance += hypot(now.x - last.x, now.y - last.y)
        dragLastLocation = now
        controller.state.pan(deltaTexCoord: SIMD2(Float(dx), Float(dy)))
        controller.stateChanged()
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        defer { mouseDownLocation = nil }
        guard dragDistance < 5 else { return }   // 拖拽结束不算点击
        var s = controller.state
        let clicked = s.complex(at: texCoord(at: convert(event.locationInWindow, from: nil)))
        if s.mode == 0 {
            s.juliaC = clicked
            s.mode = 1
            print("→ 切入 Julia 集，c 取点击处 (\(String(format: "%.4f", clicked.x)), \(String(format: "%.4f", clicked.y)))")
        } else {
            s.mode = 0
            print("→ 返回 Mandelbrot 集")
        }
        controller.state = s
        controller.stateChanged()
    }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        if event.charactersIgnoringModifiers?.lowercased() == "r" {
            controller.state = FractalViewState(aspect: controller.state.aspect)
            controller.stateChanged()
        } else {
            super.keyDown(with: event)
        }
    }
}

class FractalAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: FractalViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "分形探险家 Mandelbrot/Julia（滚轮缩放 · 拖拽平移 · 点击切 Julia · R 复位）"
        window.center()
        controller = FractalViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)   // 把窗口带到前台（从终端启动时应用未激活）
    }
}

// MARK: - 离屏导出（不开窗口：按给定视口渲一帧写 PNG）

func exportFractalPNG(path: String, center: SIMD2<Float>, scale: Float, juliaC: SIMD2<Float>? = nil, width: Int = 1920, height: Int = 1080) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let pipeline = makeFractalPipeline(device: device, colorFormat: .rgba8Unorm)
    let vertexBuffer = device.makeBuffer(
        bytes: fractalQuad,
        length: fractalQuad.count * MemoryLayout<SIMD2<Float>>.stride,
        options: .storageModeShared
    )!

    var state = FractalViewState(aspect: Float(width) / Float(height))
    state.center = center
    state.scale = scale
    if let juliaC {
        state.mode = 1
        state.juliaC = juliaC
    }

    let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    texDesc.usage = [.renderTarget, .shaderRead]
    let texture = device.makeTexture(descriptor: texDesc)!

    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = texture
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    var u = state.uniforms
    enc.setFragmentBytes(&u, length: MemoryLayout<FractalUniforms>.stride, index: 1)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fractalQuad.count)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

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
    print(describeState(state))
    print("导出 \(width)×\(height) → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runFractal() {
    let args = CommandLine.arguments

    // export 模式：fractal export out.png [re im scale [jre jim]]
    // —— 不开窗口，按视口渲一帧写 PNG；给足 6/7 个参数时切 Julia（c = jre+jim）
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        let path = args[i + 1]
        let re = args.count > i + 2 ? Float(args[i + 2]) ?? -0.6 : -0.6
        let im = args.count > i + 3 ? Float(args[i + 3]) ?? 0.0 : 0.0
        let scale = args.count > i + 4 ? Float(args[i + 4]) ?? 2.5 : 2.5
        var juliaC: SIMD2<Float>? = nil
        if args.count > i + 6, let jx = Float(args[i + 5]), let jy = Float(args[i + 6]) {
            juliaC = SIMD2(jx, jy)
        }
        exportFractalPNG(path: path, center: SIMD2(re, im), scale: scale, juliaC: juliaC)
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = FractalAppDelegate()
    app.delegate = delegate
    app.run()
}
