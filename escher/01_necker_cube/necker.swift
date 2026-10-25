import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import simd

// 上传给 GPU 的常量：
// mvp    = 正交投影 × 视图旋转（CPU 算好一个矩阵，GPU 只做一次乘法）
// params = (解读模式 0/1, 时间, 0, 0)
struct NeckerUniforms {
    var mvp: simd_float4x4
    var params: SIMD4<Float>
}

// 纸面底色：窗口 clear、导出 clear、竞争面"隐身"填充三方共用同一个常量，
// 保证任何消费路径（屏幕/PNG）看到的都是同一张纸
let paper = (r: Float(0.96), g: Float(0.95), b: Float(0.92))   // 米白，呼应埃舍尔的版画纸

// 经典 Necker 视角：沿立方体体对角线 (1,1,1) 做正交观察（等距角落视角）。
// 此时近角与远角投影到同一个中心点，外轮廓是正六边形——
// 这幅画同时是"两只"立方体的合法投影，深度解读完全歧义。
let magicYaw = Float.pi / 4                                       // 45°
let magicPitch = Float(atan(1.0 / sqrt(2.0)))                     // ≈ 35.26°（atan(1/√2)）
let pitchLimit: Float = 89.0 * Float.pi / 180                     // 自由旋转的俯仰上限（避免视向上矢量退化）

// 几何数据：position.xyz = 顶点，position.w = 语义标签
//   -1 → 棱线（永远可见、刻意不做深度测试——深度提示正是错觉要抹掉的东西）
//  0/1 → 解读 A/B 的"前面"填充（高亮当前解读；另一面 alpha=0，混合后不可见）
// 顶点顺序先填充面后棱线：两次 draw 调用按同一缓冲分区绘制，棱线叠在填充之上
func makeNeckerGeometry() -> [SIMD4<Float>] {
    // 8 个角点：下标 = x 位 + 2·y 位 + 4·z 位（坐标 ±1）
    let c: [SIMD3<Float>] = [
        SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(-1, 1, -1), SIMD3(1, 1, -1),
        SIMD3(-1, -1, 1),  SIMD3(1, -1, 1),  SIMD3(-1, 1, 1),  SIMD3(1, 1, 1),
    ]
    var v: [SIMD4<Float>] = []
    // 解读 A 的前面：z=1 棱面（投影在左下菱形区）
    for q in [c[4], c[5], c[7], c[4], c[7], c[6]] { v.append(SIMD4(q, 0)) }
    // 解读 B 的前面：z=-1 棱面（投影在右上菱形区）
    for q in [c[0], c[1], c[3], c[0], c[3], c[2]] { v.append(SIMD4(q, 1)) }
    // 12 条棱
    let e = [(0, 1), (1, 3), (3, 2), (2, 0), (4, 5), (5, 7), (7, 6), (6, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
    for (a, b) in e {
        v.append(SIMD4(c[a], -1))
        v.append(SIMD4(c[b], -1))
    }
    return v
}

// 正交投影 × 视图旋转。没有透视除法、没有深度——同尺寸的前后面正是歧义的来源
func makeMVP(yaw: Float, pitch: Float, aspect: Float, halfH: Float) -> simd_float4x4 {
    let dir = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    let fw = normalize(-dir)
    let rt = normalize(cross(fw, SIMD3<Float>(0, 1, 0)))
    let up = cross(rt, fw)
    let halfW = halfH * aspect
    // 列主序拼矩阵：clip.x = dot(v, rt)/halfW，clip.y = dot(v, up)/halfH
    // z 行全零：刻意不写深度，深度缓冲从源头就不存在
    return simd_float4x4(columns: (
        SIMD4<Float>(rt.x / halfW, up.x / halfH, 0, 0),
        SIMD4<Float>(rt.y / halfW, up.y / halfH, 0, 0),
        SIMD4<Float>(rt.z / halfW, up.z / halfH, 0, 0),
        SIMD4<Float>(0, 0, 0, 1)
    ))
}

// 着色器：一个 vertex 给所有顶点上色（棱线 / 当前解读面 / 隐藏面），fragment 原样输出
let neckerShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct NeckerUniforms {
    float4x4 mvp;
    float4 params;   // x: 解读模式（0=A / 1=B）
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut vertex_main(
    const device float4 *vertices [[buffer(0)]],
    constant NeckerUniforms &u [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    VertexOut out;
    float4 v = vertices[vid];
    out.position = u.mvp * float4(v.xyz, 1.0);
    if (v.w < 0.0) {
        out.color = float4(0.13, 0.14, 0.17, 1.0);              // 棱线：深墨色
    } else if (uint(v.w + 0.5) == uint(u.params.x + 0.5)) {
        out.color = float4(0.98, 0.755, 0.55, 1.0);             // 当前解读的"前面"：暖橘纸色（不透明）
    } else {
        out.color = float4(\(paper.r), \(paper.g), \(paper.b), 1.0);   // 竞争面：与纸同色 → 视觉上隐身
    }
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}
"""

func makeNeckerPipeline(device: MTLDevice, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let library = try! device.makeLibrary(source: neckerShaderSource, options: nil)
    guard let vf = library.makeFunction(name: "vertex_main"),
          let ff = library.makeFunction(name: "fragment_main") else {
        fatalError("着色器函数缺失：vertex_main / fragment_main")
    }
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vf
    desc.fragmentFunction = ff
    desc.colorAttachments[0].pixelFormat = colorFormat
    // 刻意不开 alpha 混合：所有像素都是不透明色（"隐身"靠与纸同色，不靠 alpha=0）。
    // 半透明在 rgba8 纹理 → CGContext 预乘解读 → PNG 的链路里会失真（见 README Pitfalls）
    return try! device.makeRenderPipelineState(descriptor: desc)
}

let modeLabel = ["解读 A：左下棱面在前（正常立方体）", "解读 B：右上棱面在前（同一幅画，深度整个翻转）"]

// MARK: - 窗口模式（自由旋转 + 滚轮缩放 + F 切换解读 + 标题栏 FPS）

class NeckerViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var faceCount = 12    // 两个填充面各 2 个三角形
    var yaw = magicYaw
    var pitch = magicPitch
    var halfH: Float = 2.0        // 正交视野半高（世界单位），滚轮缩放可调
    var mode = 0
    var frameCount = 0
    var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = NeckerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        metalView.clearColor = MTLClearColor(red: Double(paper.r), green: Double(paper.g), blue: Double(paper.b), alpha: 1)
        view = metalView
        // 重置按钮：拖歪或切了解读之后，一键回到魔法角度 + 解读 A
        let resetButton = NSButton(title: "重置", target: self, action: #selector(resetState))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.toolTip = "回到魔法角度（45°/35.26°）并恢复解读 A"
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        metalView.addSubview(resetButton)
        NSLayoutConstraint.activate([
            resetButton.trailingAnchor.constraint(equalTo: metalView.trailingAnchor, constant: -12),
            resetButton.topAnchor.constraint(equalTo: metalView.topAnchor, constant: 12),
        ])
    }

    // 重置 = 回到错觉的"标准观测条件"：魔法角度 + 默认缩放 + 解读 A
    @objc func resetState() {
        yaw = magicYaw
        pitch = magicPitch
        halfH = 2.0
        mode = 0
        print(modeLabel[0] + " · 已重置")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? NeckerView)?.controller = self
        queue = device.makeCommandQueue()
        pipelineState = makeNeckerPipeline(device: device, colorFormat: metalView.colorPixelFormat)
        let geo = makeNeckerGeometry()
        vertexBuffer = device.makeBuffer(
            bytes: geo,
            length: geo.count * MemoryLayout<SIMD4<Float>>.stride,
            options: .storageModeShared
        )
        print("Device: \(device.name)")
        print("场景：正交线框立方体（等距角落视角，近角与远角投影重合于中心点）")
        print("[Pipeline ready] 12 条棱 + A/B 双解读面 · 错觉在魔法角度 ±5° 内稳定")
        print("拖拽：自由旋转（滚轮缩放） · F：切换深度解读 · 「重置」回魔法角度")
        print(modeLabel[0])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let size = view.drawableSize
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        var u = NeckerUniforms(
            mvp: makeMVP(yaw: yaw, pitch: pitch, aspect: Float(size.width / size.height), halfH: halfH),
            params: SIMD4(Float(mode), 0, 0, 0)
        )
        enc.setVertexBytes(&u, length: MemoryLayout<NeckerUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: faceCount)             // 先画填充面
        enc.drawPrimitives(type: .line, vertexStart: faceCount, vertexCount: 24)                // 棱线叠在上面
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsWindowStart
        if elapsed >= 2.0 {
            let fps = Double(frameCount) / elapsed
            let off = max(abs(yaw - magicYaw), abs(pitch - magicPitch)) * 180 / Float.pi
            let state = off < 5 ? "✓ 错觉成立" : "✗ 已穿帮"
            view.window?.title = "Necker 立方体 · \(state) · FPS \(Int(fps)) · 自由旋转 滚轮缩放"
            print(String(format: "FPS ≈ %.1f（标题栏同步显示）", fps))
            frameCount = 0
            fpsWindowStart = now
        }
    }
}

class NeckerView: MTKView {
    weak var controller: NeckerViewController?
    var dragging = false
    var lastMouse: NSPoint = .zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        lastMouse = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let c = controller, dragging else { return }
        let now = convert(event.locationInWindow, from: nil)
        let dYaw = Float(now.x - lastMouse.x) * 0.008
        let dPitch = Float(now.y - lastMouse.y) * 0.008
        // 自由旋转：错觉只在魔法角度附近成立，转开即穿帮（标题栏实时提示）
        c.yaw += dYaw
        c.pitch = min(pitchLimit, max(-pitchLimit, c.pitch + dPitch))
        lastMouse = now
    }

    override func scrollWheel(with event: NSEvent) {
        guard let c = controller else { return }
        let f = exp(Float(event.scrollingDeltaY) * 0.01)
        c.halfH = min(6.0, max(1.0, c.halfH * f))
    }

    override func magnify(with event: NSEvent) {
        guard let c = controller else { return }
        c.halfH = min(6.0, max(1.0, c.halfH / Float(event.magnification)))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller, event.charactersIgnoringModifiers == "f" else {
            super.keyDown(with: event)
            return
        }
        c.mode = 1 - c.mode
        print(modeLabel[c.mode])
    }
}

class NeckerAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: NeckerViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Necker 立方体 · 自由旋转 · 滚轮缩放 · F 切换解读 · 重置"
        window.center()
        controller = NeckerViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 离屏导出（固定魔法角度渲一帧写 PNG；第二个参数选解读 a/b）

func exportNeckerPNG(path: String, mode: Int, width: Int = 1920, height: Int = 1080) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let pipeline = makeNeckerPipeline(device: device, colorFormat: .rgba8Unorm)
    let geo = makeNeckerGeometry()
    let vertexBuffer = device.makeBuffer(
        bytes: geo,
        length: geo.count * MemoryLayout<SIMD4<Float>>.stride,
        options: .storageModeShared
    )!

    let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    texDesc.usage = [.renderTarget, .shaderRead]
    let texture = device.makeTexture(descriptor: texDesc)!

    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = texture
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: Double(paper.r), green: Double(paper.g), blue: Double(paper.b), alpha: 1)   // 与窗口同一张"纸"

    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    var u = NeckerUniforms(
        mvp: makeMVP(yaw: magicYaw, pitch: magicPitch, aspect: Float(width) / Float(height), halfH: 2.0),
        params: SIMD4(Float(mode), 0, 0, 0)
    )
    enc.setVertexBytes(&u, length: MemoryLayout<NeckerUniforms>.stride, index: 1)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12)
    enc.drawPrimitives(type: .line, vertexStart: 12, vertexCount: 24)
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
    print("解读 \(mode == 0 ? "A" : "B") · 正交魔法角度（yaw 45° / pitch 35.26°）  尺寸 \(width)×\(height)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runNecker() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        let mode = args.count > i + 2 && args[i + 2].lowercased() == "b" ? 1 : 0
        exportNeckerPNG(path: args[i + 1], mode: mode)
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = NeckerAppDelegate()
    app.delegate = delegate
    app.run()
}
