import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// 每个泡泡的数据。SIMD4 打包避免 Swift/MSL 对齐差异：
// pr = (pos.x, pos.y, radius, 0)   pos 在"短边归一"坐标系：x ∈ [-aspect/2, aspect/2]，y ∈ [-0.5, 0.5]
// col = (r, g, b, 0)
struct MetaballData {
    var pr: SIMD4<Float>
    var col: SIMD4<Float>
}

// 每帧 uniforms：u0 = (resX, resY, threshold, ballCount)
struct MetaballUniforms {
    var u0: SIMD4<Float>
}

// 5 个泡泡的初始状态：位置（短边归一坐标）+ 速度（单位/秒）+ 颜色
let metaballInitial: [(pos: SIMD2<Float>, vel: SIMD2<Float>, color: SIMD4<Float>)] = [
    (SIMD2(-0.45,  0.10), SIMD2( 0.26,  0.17), SIMD4(0.95, 0.45, 0.40, 1)),   // 珊瑚红
    (SIMD2(-0.10, -0.15), SIMD2(-0.22,  0.24), SIMD4(0.35, 0.70, 0.95, 1)),   // 天蓝
    (SIMD2( 0.25,  0.20), SIMD2( 0.18, -0.27), SIMD4(0.98, 0.80, 0.35, 1)),   // 杏黄
    (SIMD2( 0.50, -0.10), SIMD2(-0.28, -0.14), SIMD4(0.45, 0.85, 0.60, 1)),   // 青绿
    (SIMD2( 0.05,  0.30), SIMD2( 0.12,  0.20), SIMD4(0.80, 0.55, 0.95, 1)),   // 淡紫
]
let metaballRadius: Float = 0.11

// 着色器：场强 Σ r²/d² 叠加 → 等值面 → 数值梯度法线 + 简单光照，场强加权混出泡泡颜色
let metaballShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Ball { float4 pr; float4 col; };
struct MetaballUniforms { float4 u0; };   // resX, resY, threshold, ballCount

float fieldAt(float2 p, constant Ball *balls, int n) {
    float f = 0.0;
    for (int i = 0; i < n; i++) {
        float2 d = p - balls[i].pr.xy;
        float r = balls[i].pr.z;
        float w = r * r / (dot(d, d) + 1e-6);
        f += w * w;   // 平方衰减：影响半径收得紧，泡泡分开时干净、靠近才融合
    }
    return f;
}

fragment float4 fragment_main(
    float4 fragCoord [[position]],
    constant MetaballUniforms &u [[buffer(1)]],
    constant Ball *balls [[buffer(2)]]
) {
    int n = int(u.u0.w);
    float threshold = u.u0.z;
    float aspect = u.u0.x / u.u0.y;

    // 像素坐标 → 短边归一坐标（与 CPU 侧物理同一坐标系）
    // Metal 像素坐标 y 向下，物理世界 y 向上——翻转后画面方向与鼠标映射一致
    float2 p = (float2(fragCoord.x, u.u0.y - fragCoord.y) - 0.5 * u.u0.xy) / u.u0.y;

    float f = fieldAt(p, balls, n);

    // 场强加权平均出"这一处属于哪个泡泡"的颜色
    float3 colAcc = float3(0.0);
    for (int i = 0; i < n; i++) {
        float2 d = p - balls[i].pr.xy;
        float r = balls[i].pr.z;
        float w = r * r / (dot(d, d) + 1e-6);
        colAcc += w * w * balls[i].col.xyz;
    }
    float3 ballCol = colAcc / max(f, 1e-6);

    // 把场强当高度场：2D 梯度 + z 分量构成 3D 法线，得到"凸起圆垫"式立体光照
    // （直接用 2D 径向梯度打光会得到射线状楔形高光——dot 只随角度变化，等值线是从球心发出的射线）
    float e = 0.004;
    float2 gvec = float2(fieldAt(p + float2(e, 0), balls, n) - fieldAt(p - float2(e, 0), balls, n),
                         fieldAt(p + float2(0, e), balls, n) - fieldAt(p - float2(0, e), balls, n));
    float glen = length(gvec);
    // z 用常数而不是与梯度成比例：中心处梯度趋零→法线朝向观众（平），
    // 边缘梯度大→法线侧倾（立体）；z 若随梯度缩放，法线方向只随角度变，楔形高光必然回归
    float3 normal = normalize(float3(-gvec, 0.35));

    float3 lightDir = normalize(float3(-0.5, 0.7, 0.6));        // 左上前方来光
    float3 halfV = normalize(lightDir + float3(0.0, 0.0, 1.0)); // Blinn-Phong 半程向量
    float shade = 0.45 + 0.55 * clamp(dot(normal, lightDir), 0.0, 1.0);
    float spec = pow(clamp(dot(normal, halfV), 0.0, 1.0), 48.0);

    float3 lit = ballCol * shade + float3(spec);

    // 背景深色竖渐变
    float3 bg = mix(float3(0.06, 0.07, 0.12), float3(0.13, 0.15, 0.22), p.y + 0.5);

    // 等值面抗锯齿过渡：f 越过阈值越深越显示泡泡色
    float aa = smoothstep(threshold - 0.06, threshold + 0.06, f);
    return float4(mix(bg, lit, aa), 1.0);
}
"""

let metaballVertexSource = """
#include <metal_stdlib>
using namespace metal;

struct MetaballVertexOut {
    float4 position [[position]];
};

vertex MetaballVertexOut vertex_main(
    const device float2 *positions [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    MetaballVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    return out;
}
"""

let metaballQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

func makeMetaballPipeline(device: MTLDevice, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let library = try! device.makeLibrary(source: metaballVertexSource + "\n" + metaballShaderSource, options: nil)
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

func makeMetaballBalls(width: Float, height: Float) -> [MetaballData] {
    metaballInitial.map { MetaballData(pr: SIMD4($0.pos.x, $0.pos.y, metaballRadius, 0), col: $0.color) }
}

// MARK: - 窗口模式（CPU 物理积分 + 鼠标拖拽 + 标题栏 FPS）

class MetaballViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var ballBuffer: MTLBuffer!

    var positions: [SIMD2<Float>] = []
    var velocities: [SIMD2<Float>] = []
    var aspect: Float = 800.0 / 600.0
    var lastTime: Double = 0
    var frameCount = 0
    var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    var grabbedIndex: Int? = nil
    var lastMousePos: SIMD2<Float> = .zero

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = MetaballView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? MetaballView)?.controller = self
        commandQueue = device.makeCommandQueue()
        pipelineState = makeMetaballPipeline(device: device, colorFormat: metalView.colorPixelFormat)
        vertexBuffer = device.makeBuffer(
            bytes: metaballQuad,
            length: metaballQuad.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        )
        positions = metaballInitial.map { $0.pos }
        velocities = metaballInitial.map { $0.vel }
        ballBuffer = device.makeBuffer(
            length: metaballInitial.count * MemoryLayout<MetaballData>.stride,
            options: .storageModeShared
        )
        print("Device: \(device.name)")
        print("泡泡数：\(metaballInitial.count)（拖拽任意一个；两球靠近会融合）")
        print("[Pipeline ready] vertex_main + fragment_main · 帧率见窗口标题栏")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    // CPU 物理：匀速漂移 + 边界反弹；被拖拽的泡泡改由鼠标目标位驱动
    func stepPhysics(dt: Float) {
        let bx = aspect / 2 - metaballRadius
        let by = 0.5 - metaballRadius
        for i in 0..<positions.count {
            if i == grabbedIndex { continue }
            positions[i] += velocities[i] * dt
            if abs(positions[i].x) > bx { positions[i].x = positions[i].x.sign == .minus ? -bx : bx; velocities[i].x *= -1 }
            if abs(positions[i].y) > by { positions[i].y = positions[i].y.sign == .minus ? -by : by; velocities[i].y *= -1 }
        }
        if let g = grabbedIndex {
            // 抓住的泡泡向鼠标位置平滑追随（lerp），松手时把指针速度作为新速度
            let target = lastMousePos
            let prev = positions[g]
            positions[g] = positions[g] + (target - positions[g]) * min(1.0, dt * 14)
            velocities[g] = (positions[g] - prev) / max(dt, 1e-4)
        }
    }

    func syncBallBuffer() {
        var data = zip(positions, metaballInitial).map { (p, init0) in
            MetaballData(pr: SIMD4(p.x, p.y, metaballRadius, 0), col: init0.color)
        }
        ballBuffer!.contents().copyMemory(from: &data, byteCount: data.count * MemoryLayout<MetaballData>.stride)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        aspect = Float(size.width / max(size.height, 1))
    }

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        if lastTime == 0 { lastTime = now }
        let dt = Float(min(now - lastTime, 0.05))
        lastTime = now

        let size = view.drawableSize
        aspect = Float(size.width / max(size.height, 1))
        stepPhysics(dt: dt)
        syncBallBuffer()

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        var u = MetaballUniforms(u0: SIMD4(Float(size.width), Float(size.height), 1.0, Float(metaballInitial.count)))
        enc.setFragmentBytes(&u, length: MemoryLayout<MetaballUniforms>.stride, index: 1)
        enc.setFragmentBuffer(ballBuffer, offset: 0, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: metaballQuad.count)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        // FPS 统计：每 2 秒刷新一次窗口标题栏（HUD）
        frameCount += 1
        let nowWall = CFAbsoluteTimeGetCurrent()
        let elapsed = nowWall - fpsWindowStart
        if elapsed >= 2.0 {
            let fps = Double(frameCount) / elapsed
            view.window?.title = String(format: "Metaballs 果冻泡泡 · FPS %.0f · 拖拽泡泡玩", fps)
            print(String(format: "FPS ≈ %.1f（标题栏同步显示）", fps))
            frameCount = 0
            fpsWindowStart = nowWall
        }
    }

    // 事件坐标 → 短边归一坐标
    func scenePoint(at point: NSPoint) -> SIMD2<Float> {
        let b = metalView.bounds
        return SIMD2(Float(point.x / b.width - 0.5) * aspect, Float(0.5 - point.y / b.height))
    }

    func grab(at point: NSPoint) {
        let p = scenePoint(at: point)
        var best = -1
        var bestDist = Float.greatestFiniteMagnitude
        for (i, pos) in positions.enumerated() {
            let d = simd_distance(pos, p)
            if d < bestDist { bestDist = d; best = i }
        }
        if bestDist < metaballRadius * 1.6 {
            grabbedIndex = best
            lastMousePos = p
            print("抓起 \(best + 1) 号泡泡")
        }
    }

    func drag(to point: NSPoint) {
        guard grabbedIndex != nil else { return }
        lastMousePos = scenePoint(at: point)
    }

    func release() {
        if let g = grabbedIndex {
            let speed = simd_length(velocities[g])
            if speed > 3.0 { velocities[g] = velocities[g] / speed * 3.0 }   // 松手甩出的速度封顶
            print("放开 \(g + 1) 号泡泡（甩出速度 \(String(format: "%.2f", speed))）")
        }
        grabbedIndex = nil
    }
}

class MetaballView: MTKView {
    weak var controller: MetaballViewController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        controller?.grab(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.drag(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.release()
    }
}

class MetaballAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: MetaballViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Metaballs 果冻泡泡 · 拖拽泡泡玩"
        window.center()
        controller = MetaballViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)   // 把窗口带到前台（从终端启动时应用未激活）
    }
}

// MARK: - 离屏导出（按固定布局渲一帧写 PNG）

func exportMetaballPNG(path: String, width: Int = 1920, height: Int = 1080) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let pipeline = makeMetaballPipeline(device: device, colorFormat: .rgba8Unorm)
    let vertexBuffer = device.makeBuffer(
        bytes: metaballQuad,
        length: metaballQuad.count * MemoryLayout<SIMD2<Float>>.stride,
        options: .storageModeShared
    )!
    var balls = makeMetaballBalls(width: Float(width), height: Float(height))
    let ballBuffer = device.makeBuffer(
        bytes: &balls,
        length: balls.count * MemoryLayout<MetaballData>.stride,
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
    var u = MetaballUniforms(u0: SIMD4(Float(width), Float(height), 1.0, Float(balls.count)))
    enc.setFragmentBytes(&u, length: MemoryLayout<MetaballUniforms>.stride, index: 1)
    enc.setFragmentBuffer(ballBuffer, offset: 0, index: 2)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: metaballQuad.count)
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
    print("泡泡 5 个（固定布局）  尺寸 \(width)×\(height)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runMetaball() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        exportMetaballPNG(path: args[i + 1])
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = MetaballAppDelegate()
    app.delegate = delegate
    app.run()
}
