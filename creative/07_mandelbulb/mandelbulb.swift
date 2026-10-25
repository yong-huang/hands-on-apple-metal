import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// 相机与造型参数。SIMD4 打包避免 Swift/MSL 对齐差异：
// u0 = (yaw, pitch, dist, power)   power 是 Mandelbulb 的幂次 n，2~12 可调
// u1 = (resX, resY, 0, 0)
struct MandelbulbUniforms {
    var u0: SIMD4<Float>
    var u1: SIMD4<Float>
}

// 片元着色器：Mandelbulb 距离估计 + 球体追踪 + orbit trap 调色
let mandelbulbShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct MandelbulbUniforms {
    float4 u0;   // yaw, pitch, dist, power
    float4 u1;   // resX, resY, 0, 0
};

// Mandelbulb 距离估计：球坐标下的 z → zⁿ + c 迭代（n=power）。
// dr 累积"半径放大率"（导数的链式法则），对数换算出保守距离；
// trapOut 带回迭代途中半径的最小值（orbit trap），用于表面调色。
float bulbDE(float3 pos, float power, thread float *trapOut) {
    float3 z = pos;
    float dr = 1.0;
    float trap = 1e10;
    for (int i = 0; i < 8; i++) {
        float r = length(z);
        dr = pow(r, power - 1.0) * power * dr + 1.0;   // 导数链式累积（逃逸轮不计入）
        float theta = acos(clamp(z.z / max(r, 1e-6), -1.0, 1.0));   // 极角，防除零
        float phi = atan2(z.y, z.x);                                 // 方位角
        float zr = pow(r, power);
        theta *= power;
        phi *= power;
        z = zr * float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)) + pos;
        trap = min(trap, length(z));
        if (dot(z, z) > 256.0) { break; }              // 逃逸判定在更新之后，逃逸半径 16
    }
    *trapOut = trap;
    // 关键：距离用"逃逸后"的 z 计算。若误用循环里的旧半径，DE 处处≈0，
    // 光线一起步就满足命中阈值——渲染出的是带环纹的球而不是分形
    float m = dot(z, z);
    return 0.5 * log(max(m, 1e-6)) * sqrt(m) / dr;
}

// 场 = 放大 1.15 倍的 Mandelbulb。缩放集合时距离要同步乘回去
float mapScene(float3 p, float power) {
    float trap;
    return bulbDE(p / 1.15, power, &trap) * 1.15;
}

// 数值梯度求法线：xyz 各正负方向共 6 次距离采样
float3 calcNormal(float3 p, float power) {
    float e = 0.0004;
    float2 h = float2(e, 0.0);
    return normalize(float3(
        mapScene(p + h.xyy, power) - mapScene(p - h.xyy, power),
        mapScene(p + h.yxy, power) - mapScene(p - h.yxy, power),
        mapScene(p + h.yyx, power) - mapScene(p - h.yyx, power)));
}

// 环境光遮蔽：沿法线采 4 个高度，距离估计比自由空间小多少 → 遮蔽程度
float calcAO(float3 p, float3 n, float power) {
    float occ = 0.0, sca = 1.0;
    for (int i = 0; i < 4; i++) {
        float h = 0.008 + 0.06 * float(i);
        occ += (h - mapScene(p + n * h, power)) * sca;
        sca *= 0.7;
    }
    return clamp(1.0 - 3.0 * occ, 0.0, 1.0);
}

fragment float4 fragment_main(
    float4 fragCoord [[position]],
    constant MandelbulbUniforms &u [[buffer(1)]]
) {
    float2 res = u.u1.xy;
    float yaw = u.u0.x, pitch = u.u0.y, dist = u.u0.z, power = u.u0.w;

    // Metal 像素坐标 y 向下，世界 y 向上——翻转后再构造射线，否则画面上下颠倒
    float2 uv = (float2(fragCoord.x, res.y - fragCoord.y) - 0.5 * res) / res.y;
    float3 ro = dist * float3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw));
    float3 fw = normalize(-ro);
    float3 rt = normalize(cross(fw, float3(0.0, 1.0, 0.0)));
    float3 up = cross(rt, fw);
    float3 rd = normalize(fw * 1.7 + uv.x * rt + uv.y * up);

    // 球体追踪：距离估计是保守值，步长再乘 0.9 防高估穿透
    float t = 0.0;
    bool hit = false;
    for (int i = 0; i < 110; i++) {
        float d = mapScene(ro + rd * t, power);
        if (d < 0.0006 * t) { hit = true; break; }
        t += min(d * 0.9, 0.4);   // 步长上限 0.4：远点处 DE 会高估，不封顶会一步跨过整个分形
        if (t > 8.0) { break; }
    }

    // 天空：按射线高度的竖直渐变
    float3 sky = mix(float3(0.30, 0.34, 0.46), float3(0.75, 0.82, 0.92), clamp(rd.y * 0.5 + 0.5, 0.0, 1.0));
    float3 col = sky;

    if (hit) {
        float3 p = ro + rd * t;
        float trap;
        bulbDE(p / 1.15, power, &trap);
        float3 n = calcNormal(p, power);
        float3 lightDir = normalize(float3(0.55, 0.75, 0.4));

        float diff = clamp(dot(n, lightDir), 0.0, 1.0);
        float ao = calcAO(p, n, power);
        // orbit trap 调色：靠近"核心轨迹"的地方偏金，远离偏陶土红
        float3 base = mix(float3(0.78, 0.42, 0.28), float3(0.96, 0.86, 0.62), smoothstep(0.6, 1.1, trap));
        float rim = pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), 3.0);   // 边缘光
        col = base * (0.22 + 0.78 * diff * ao) + sky * ao * 0.12 + rim * 0.25;
    }

    return float4(pow(clamp(col, 0.0, 1.0), float3(0.4545)), 1.0);   // gamma
}
"""

let mandelbulbVertexSource = """
#include <metal_stdlib>
using namespace metal;

struct MandelbulbVertexOut {
    float4 position [[position]];
};

vertex MandelbulbVertexOut vertex_main(
    const device float2 *positions [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    MandelbulbVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    return out;
}
"""

let mandelbulbQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

func makeMandelbulbPipeline(device: MTLDevice, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let library = try! device.makeLibrary(source: mandelbulbVertexSource + "\n" + mandelbulbShaderSource, options: nil)
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

// MARK: - 窗口模式（拖拽旋转 + 滚轮缩放 + ↑↓ 调 power + 标题栏 FPS）

class MandelbulbViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var yaw: Float = 0.9
    var pitch: Float = 0.25
    var dist: Float = 5.0
    var power: Float = 8
    var lastTime: Double = 0
    var frameCount = 0
    var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = MandelbulbView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? MandelbulbView)?.controller = self
        queue = device.makeCommandQueue()
        pipelineState = makeMandelbulbPipeline(device: device, colorFormat: metalView.colorPixelFormat)
        vertexBuffer = device.makeBuffer(
            bytes: mandelbulbQuad,
            length: mandelbulbQuad.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        )
        print("Device: \(device.name)")
        print("造型：Mandelbulb power=8（↑↓ 调 power 2~12，滚轮缩放，拖拽旋转）")
        print("[Pipeline ready] vertex_main + fragment_main · 距离估计球体追踪 · 帧率见标题栏")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        if lastTime == 0 { lastTime = now }
        lastTime = now

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let size = view.drawableSize
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        var u = MandelbulbUniforms(
            u0: SIMD4(yaw, pitch, dist, power),
            u1: SIMD4(Float(size.width), Float(size.height), 0, 0)
        )
        enc.setFragmentBytes(&u, length: MemoryLayout<MandelbulbUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mandelbulbQuad.count)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        frameCount += 1
        let elapsed = now - fpsWindowStart
        if elapsed >= 2.0 {
            let fps = Double(frameCount) / elapsed
            view.window?.title = String(format: "Mandelbulb power=%.0f · FPS %.0f · 拖拽旋转 滚轮缩放 ↑↓调power", power, fps)
            print(String(format: "FPS ≈ %.1f（标题栏同步显示）", fps))
            frameCount = 0
            fpsWindowStart = now
        }
    }
}

class MandelbulbView: MTKView {
    weak var controller: MandelbulbViewController?
    var dragging = false
    var lastMouse: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard let c = controller else { return super.scrollWheel(with: event) }
        let factor = pow(1.2, Float(-event.deltaY))
        c.dist = min(6.0, max(2.0, c.dist * factor))
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 126: c.power = min(12, c.power + 1)   // ↑
        case 125: c.power = max(2, c.power - 1)    // ↓
        default: return super.keyDown(with: event)
        }
        print("power → \(Int(c.power))")
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        lastMouse = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller, dragging else { return }
        let now = convert(event.locationInWindow, from: nil)
        c.yaw += Float(now.x - lastMouse.x) * 0.006
        c.pitch = min(1.35, max(-1.35, c.pitch + Float(now.y - lastMouse.y) * 0.006))
        lastMouse = now
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }
}

class MandelbulbAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: MandelbulbViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mandelbulb · 拖拽旋转 滚轮缩放 ↑↓调power"
        window.center()
        controller = MandelbulbViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 离屏导出（固定相机渲一帧写 PNG，并打印单帧渲染耗时——验收数据）

func exportMandelbulbPNG(path: String, power: Float, width: Int = 1920, height: Int = 1080) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let pipeline = makeMandelbulbPipeline(device: device, colorFormat: .rgba8Unorm)
    let vertexBuffer = device.makeBuffer(
        bytes: mandelbulbQuad,
        length: mandelbulbQuad.count * MemoryLayout<SIMD2<Float>>.stride,
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
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    var u = MandelbulbUniforms(u0: SIMD4(0.9, 0.3, 5.0, power), u1: SIMD4(Float(width), Float(height), 0, 0))
    enc.setFragmentBytes(&u, length: MemoryLayout<MandelbulbUniforms>.stride, index: 1)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mandelbulbQuad.count)
    enc.endEncoding()
    let t0 = CFAbsoluteTimeGetCurrent()
    cb.commit()
    cb.waitUntilCompleted()
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000

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
    print("造型：Mandelbulb power=\(Int(power))  尺寸 \(width)×\(height)  单帧渲染 \(String(format: "%.1f", ms)) ms")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runMandelbulb() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        let path = args[i + 1]
        let power = args.count > i + 2 ? (Float(args[i + 2]) ?? 8) : 8
        exportMandelbulbPNG(path: path, power: power)
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = MandelbulbAppDelegate()
    app.delegate = delegate
    app.run()
}
