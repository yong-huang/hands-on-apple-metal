import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// 每帧传给片元着色器的 uniforms：时间驱动流动，
// a/b/c/d 是余弦调色板系数（palette(t) = a + b*cos(2π(c*t+d))），换配色只换系数、不重建管线。
// pad 用 SIMD4 补齐：SIMD4 与 MSL float4 都是 16 字节对齐，保证 Swift 与 MSL 内存布局逐字节一致
struct PlasmaUniforms {
    var time: Float
    var pad: SIMD4<Float> = .zero
    var pa: SIMD4<Float>
    var pb: SIMD4<Float>
    var pc: SIMD4<Float>
    var pd: SIMD4<Float>
}

// 三套配色：极光 / 晚霞 / 深海（IQ cosine palette，通道相位错开才有色相流动）
let plasmaPalettes: [(name: String, a: SIMD4<Float>, b: SIMD4<Float>, c: SIMD4<Float>, d: SIMD4<Float>)] = [
    (name: "极光", a: SIMD4(0.35, 0.50, 0.45, 1), b: SIMD4(0.35, 0.40, 0.40, 1), c: SIMD4(1, 1, 1, 1), d: SIMD4(0.00, 0.20, 0.40, 1)),
    (name: "晚霞", a: SIMD4(0.50, 0.30, 0.30, 1), b: SIMD4(0.45, 0.25, 0.25, 1), c: SIMD4(1, 1, 0.7, 1), d: SIMD4(0.00, 0.10, 0.25, 1)),
    (name: "深海", a: SIMD4(0.25, 0.40, 0.50, 1), b: SIMD4(0.25, 0.30, 0.35, 1), c: SIMD4(1, 1, 1, 1), d: SIMD4(0.10, 0.30, 0.50, 1)),
]

// 着色器源码内嵌：运行时经 device.makeLibrary(source:) 编译，无需 .metal 文件与构建阶段配置
let plasmaShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct PlasmaUniforms {
    float time;
    float4 pad;
    float4 pa;
    float4 pb;
    float4 pc;
    float4 pd;
};

struct PlasmaVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex PlasmaVertexOut vertex_main(
    const device float2 *positions [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    PlasmaVertexOut out;
    // 顶点只给 NDC 坐标；texCoord 由 NDC 线性映射到 [0,1]，全屏四边形不需要逐顶点 UV
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = positions[vid].xy * 0.5 + 0.5;
    return out;
}

// 余弦调色板：四个通道相位错开的 cos 叠加，把一个标量场映射成平滑多色
float3 pal(float t, float4 a, float4 b, float4 c, float4 d) {
    return a.xyz + b.xyz * cos(6.28318 * (c.xyz * t + d.xyz));
}

fragment float4 fragment_main(
    PlasmaVertexOut in [[stage_in]],
    constant PlasmaUniforms &u [[buffer(1)]]
) {
    float2 p = in.texCoord * 2.0 - 1.0;   // [0,1] → [-1,1]，中心为原点
    float t = u.time;

    // 四组不同相位/频率的正弦叠加：x 向、y 向、对角向、径向——经典 polar sine plasma
    float v = 0.0;
    v += sin(p.x * 3.0 + t);
    v += sin(p.y * 3.5 + t * 1.3);
    v += sin((p.x + p.y) * 2.5 + t * 0.7);
    v += sin(length(p) * 4.0 - t * 1.1);
    v = v * 0.125 + 0.5;                  // 4 项各 [-1,1] → 归一到 [0,1]

    float3 col = pal(v, u.pa, u.pb, u.pc, u.pd);
    return float4(clamp(col, 0.0, 1.0), 1.0);
}
"""

// 全屏四边形：两个三角形、6 个 NDC 顶点，覆盖整个视口
let plasmaQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

func makePlasmaUniforms(time: Float, paletteIndex: Int) -> PlasmaUniforms {
    let p = plasmaPalettes[paletteIndex % plasmaPalettes.count]
    return PlasmaUniforms(time: time, pa: p.a, pb: p.b, pc: p.c, pd: p.d)
}

func makePlasmaLibraryAndFunctions(device: MTLDevice) -> (MTLLibrary, MTLFunction, MTLFunction) {
    let library = try! device.makeLibrary(source: plasmaShaderSource, options: nil)
    guard let vf = library.makeFunction(name: "vertex_main"),
          let ff = library.makeFunction(name: "fragment_main") else {
        fatalError("着色器函数缺失：vertex_main / fragment_main")
    }
    return (library, vf, ff)
}

func makePlasmaPipeline(device: MTLDevice, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let (_, vf, ff) = makePlasmaLibraryAndFunctions(device: device)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vf
    desc.fragmentFunction = ff
    desc.colorAttachments[0].pixelFormat = colorFormat
    return try! device.makeRenderPipelineState(descriptor: desc)
}

func pixelFormatName(_ f: MTLPixelFormat) -> String {
    switch f {
    case .bgra8Unorm: return "bgra8Unorm"
    case .bgra8Unorm_srgb: return "bgra8Unorm_srgb"
    case .rgba8Unorm: return "rgba8Unorm"
    case .rgba16Float: return "rgba16Float"
    default: return "raw(\(f.rawValue))"
    }
}

func printPlasmaHeader(device: MTLDevice) {
    print("Device: \(device.name)")
    print("配色方案：1/\(plasmaPalettes.count) \(plasmaPalettes[0].name)（窗口内按 C 键循环切换）")
}

// MARK: - 窗口模式（MTKView 实时动画）

class PlasmaViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var startTime = CFAbsoluteTimeGetCurrent()
    var paletteIndex = 0

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = PlasmaView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? PlasmaView)?.controller = self
        commandQueue = device.makeCommandQueue()
        pipelineState = makePlasmaPipeline(device: device, colorFormat: metalView.colorPixelFormat)
        vertexBuffer = device.makeBuffer(
            bytes: plasmaQuad,
            length: plasmaQuad.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        )
        printPlasmaHeader(device: device)
        print("[Pipeline ready] vertex_main + fragment_main（\(pixelFormatName(metalView.colorPixelFormat))）")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)   // 让自绘视图接收 C 键
    }

    func encodeFrame(encoder: MTLRenderCommandEncoder, time: Float) {
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        var u = makePlasmaUniforms(time: time, paletteIndex: paletteIndex)
        encoder.setFragmentBytes(&u, length: MemoryLayout<PlasmaUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: plasmaQuad.count)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let time = Float(CFAbsoluteTimeGetCurrent() - startTime)
        encodeFrame(encoder: enc, time: time)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

// MTKView 默认不接受键盘焦点，子类化以接收 C 键
class PlasmaView: MTKView {
    weak var controller: PlasmaViewController?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "c", let controller {
            controller.paletteIndex = (controller.paletteIndex + 1) % plasmaPalettes.count
            print("配色 → \(controller.paletteIndex + 1)/\(plasmaPalettes.count) \(plasmaPalettes[controller.paletteIndex].name)")
        } else {
            super.keyDown(with: event)
        }
    }
}

class PlasmaAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: PlasmaViewController!
    var initialPalette = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Plasma 极光渐变板（按 C 切换配色）"
        window.center()
        controller = PlasmaViewController()
        controller.paletteIndex = initialPalette
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)   // 把窗口带到前台（从终端启动时应用未激活）
    }
}

// MARK: - 离屏导出（不开窗口：渲染一帧写 PNG，验收用）

func exportPlasmaPNG(path: String, paletteIndex: Int, time: Float, width: Int = 1920, height: Int = 1080) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let pipeline = makePlasmaPipeline(device: device, colorFormat: .rgba8Unorm)
    let vertexBuffer = device.makeBuffer(
        bytes: plasmaQuad,
        length: plasmaQuad.count * MemoryLayout<SIMD2<Float>>.stride,
        options: .storageModeShared
    )!

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
    let vc = PlasmaViewController(nibName: nil, bundle: nil)
    vc.pipelineState = pipeline
    vc.vertexBuffer = vertexBuffer
    vc.encodeFrame(encoder: enc, time: time)
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
    let palette = plasmaPalettes[paletteIndex % plasmaPalettes.count]
    print("导出 \(width)×\(height) → \(path)（配色：\(palette.name)，时间 \(time)s）")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runPlasma() {
    let args = CommandLine.arguments

    // export 模式：plasma export out.png [palette] —— 不开窗口，离屏渲一帧写 PNG。
    // palette 与窗口模式 --palette 一致按 1 计（1=极光），此处转 0 基索引并收敛到有效范围
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        let path = args[i + 1]
        let paletteArg = args.count > i + 2 ? (Int(args[i + 2]) ?? 1) : 1
        let paletteIndex = min(max(paletteArg - 1, 0), plasmaPalettes.count - 1)
        exportPlasmaPNG(path: path, paletteIndex: paletteIndex, time: 6.28)
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = PlasmaAppDelegate()
    if let i = args.firstIndex(of: "--palette"), args.count > i + 1, let p = Int(args[i + 1]), (1...plasmaPalettes.count).contains(p) {
        delegate.initialPalette = p - 1
    }
    app.delegate = delegate
    app.run()
}
