import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import simd

// 纸面底色：窗口 clear、导出 clear 共用（同 01/02 实验）
let paper = (r: Float(0.96), g: Float(0.95), b: Float(0.92))

// ---- 几何参数 ----
// 立方体半边长 1；框架棱宽 w；两根短梁沿视线方向的平移量 mu。
// 断裂角 ≈ asin(w / 2mu)：偏转 α 时 F、B 在接缝处错开 2mu·sinα，超过梁宽即断开
let cubeHalf: Float = 1.0
let barW: Float = 0.22
let mu: Float = 1.4
let inkFrame = SIMD4<Float>(0.20, 0.21, 0.24, 1)     // 框架：中墨
let inkFront = SIMD4<Float>(0.40, 0.42, 0.48, 1)     // 前梁 F：亮（读作"近"）
let inkBack = SIMD4<Float>(0.09, 0.10, 0.12, 1)      // 后梁 B：暗（读作"远"）

// 魔法角度：视线方向 d = normalize(1.35, 0.9, 1.0) 的 3/4 视角，
// F（下前）与 B（上后）沿 d 平移后投影续接成同一根竖梁
let magicDir = normalize(SIMD3<Float>(1.35, 0.9, 1.0))
let magicYaw = atan2(magicDir.x, magicDir.z)
let magicPitch = asin(magicDir.y)
let pitchLimit: Float = 89.0 * Float.pi / 180

// 顶点格式：pos.xyz + nrm.xyz + color.rgb（同 02 实验）
struct BelvedereVertex {
    var pos: SIMD4<Float>
    var nrm: SIMD4<Float>
    var color: SIMD4<Float>
}

struct BelvedereUniforms {
    var mvp: simd_float4x4
    var light: SIMD4<Float>
}

// ---- 几何构建 ----
func boxInto(_ out: inout [BelvedereVertex], center: SIMD3<Float>,
             axisU: SIMD3<Float>, axisV: SIMD3<Float>, axisW: SIMD3<Float>,
             half: SIMD3<Float>, color: SIMD4<Float>) {
    let axes = [axisU, axisV, axisW]
    for f in 0..<6 {
        let axis = f / 2
        let sign: Float = f % 2 == 0 ? 1 : -1
        let n = axes[axis] * sign
        let (a1, a2) = (axes[(axis + 1) % 3], axes[(axis + 2) % 3])
        let h1 = half[(axis + 1) % 3], h2 = half[(axis + 2) % 3]
        let c = center + n * half[axis]
        let p00 = c - a1 * h1 - a2 * h2, p10 = c + a1 * h1 - a2 * h2
        let p11 = c + a1 * h1 + a2 * h2, p01 = c - a1 * h1 + a2 * h2
        for p in [p00, p10, p11, p00, p11, p01] {
            out.append(BelvedereVertex(pos: SIMD4(p, 1), nrm: SIMD4(n, 0), color: color))
        }
    }
}

func makeBelvedereGeometry() -> [BelvedereVertex] {
    var v: [BelvedereVertex] = []
    let h = cubeHalf, w = barW
    // 框架：12 条棱，去掉前左竖棱 (x,y)=(-1,-1)——它的位置由 F+B 两段短梁顶替
    let dirs: [(SIMD3<Float>, String)] = [(SIMD3(1, 0, 0), "x"), (SIMD3(0, 1, 0), "y"), (SIMD3(0, 0, 1), "z")]
    for (dir, axis) in dirs {
        let fixed: [SIMD3<Float>]
        switch axis {
        case "x": fixed = [SIMD3(0, -1, -1), SIMD3(0, -1, 1), SIMD3(0, 1, -1), SIMD3(0, 1, 1)]
        case "y": fixed = [SIMD3(-1, 0, -1), SIMD3(-1, 0, 1), SIMD3(1, 0, -1), SIMD3(1, 0, 1)]
        default:  fixed = [SIMD3(-1, -1, 0), SIMD3(-1, 1, 0), SIMD3(1, -1, 0), SIMD3(1, 1, 0)]
        }
        for f in fixed {
            if axis == "z" && f.x > 0 && f.y > 0 { continue }   // 近竖棱：留给 F+B
            let a = f - dir * h, b = f + dir * h
            let others = [SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1)]
                .filter { abs(dot($0, dir)) < 0.5 }
            boxInto(&v, center: (a + b) * 0.5,
                    axisU: dir, axisV: others[0], axisW: others[1],
                    half: SIMD3(h, w / 2, w / 2), color: inkFrame)
        }
    }
    // 前梁 F：贴着近竖棱下半段的**像**（image z ∈ [-1, 0.02]），整体沿视线前移 mu——
    // 沿视线平移不改变投影，所以它恰好盖住框架底角交叉处（真的在前面）
    // 顶部一块后梁同色盖板：藏住 F 的端面，接缝在魔法角度下不可见
    let fBase = SIMD3(1, 1, -0.49) + magicDir * mu
    boxInto(&v, center: fBase,
            axisU: SIMD3(0, 0, 1), axisV: SIMD3(1, 0, 0), axisW: SIMD3<Float>(0, 1, 0),
            half: SIMD3(0.51, barW / 2, barW / 2), color: inkFront)
    boxInto(&v, center: SIMD3(1, 1, 0.02) + magicDir * mu + SIMD3(0, 0, 0.003),
            axisU: SIMD3(1, 0, 0), axisV: SIMD3(0, 1, 0), axisW: SIMD3<Float>(0, 0, 1),
            half: SIMD3(barW / 2, barW / 2, 0.0025), color: inkBack)
    // 后梁 B：贴着近竖棱上半段的**像**（image z ∈ [0, 1]），整体沿视线后移 mu——
    // 框架顶部横棱从它前面经过（真的把它压在后面）
    let bBase = SIMD3(1, 1, 0.5) - magicDir * mu
    boxInto(&v, center: bBase,
            axisU: SIMD3(0, 0, 1), axisV: SIMD3(1, 0, 0), axisW: SIMD3<Float>(0, 1, 0),
            half: SIMD3(0.5, barW / 2, barW / 2), color: inkBack)
    return v
}

// ---- 投影：正交相机，带深度行（遮挡是本错觉的机制）----
func makeMVP(yaw: Float, pitch: Float, aspect: Float, halfH: Float) -> simd_float4x4 {
    let dist: Float = 9.0
    let dir = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    let fw = normalize(-dir)
    // 立方体的竖棱沿世界 z：相机 up 取 z-up，竖棱投影才能保持竖直
    let rt = normalize(cross(fw, SIMD3<Float>(0, 0, 1)))
    let up = cross(rt, fw)
    let halfW = halfH * aspect
    let zNear: Float = 2.0, zFar: Float = 20.0   // 自由旋转后视深范围 ≈ [5.8, 12.2]
    let q = 1 / (zFar - zNear)
    return simd_float4x4(columns: (
        SIMD4<Float>(rt.x / halfW, up.x / halfH, -dir.x * q, 0),
        SIMD4<Float>(rt.y / halfW, up.y / halfH, -dir.y * q, 0),
        SIMD4<Float>(rt.z / halfW, up.z / halfH, -dir.z * q, 0),
        SIMD4<Float>(0, 0, (dist - zNear) * q, 1)
    ))
}

// ---- 着色器：面平坦 Lambert + 逐顶点基色（同 02 实验）----
let belvedereShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct BelvedereUniforms {
    float4x4 mvp;
    float4 light;
};

struct Vertex {
    float4 pos;
    float4 nrm;
    float4 color;
};

struct VertexOut {
    float4 position [[position]];
    float3 nrm;
    float3 color;
};

vertex VertexOut vertex_main(
    const device Vertex *vertices [[buffer(0)]],
    constant BelvedereUniforms &u [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    VertexOut out;
    out.position = u.mvp * vertices[vid].pos;
    out.nrm = vertices[vid].nrm.xyz;
    out.color = vertices[vid].color.rgb;
    return out;
}

fragment float4 fragment_main(
    VertexOut in [[stage_in]],
    constant BelvedereUniforms &u [[buffer(1)]]
) {
    float diff = clamp(dot(normalize(in.nrm), u.light.xyz), 0.0, 1.0);
    return float4(in.color * (0.38 + 0.62 * diff), 1.0);
}
"""

func makeBelvederePipeline(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let library = try! device.makeLibrary(source: belvedereShaderSource, options: nil)
    guard let vf = library.makeFunction(name: "vertex_main"),
          let ff = library.makeFunction(name: "fragment_main") else {
        fatalError("着色器函数缺失：vertex_main / fragment_main")
    }
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vf
    desc.fragmentFunction = ff
    desc.colorAttachments[0].pixelFormat = colorFormat
    desc.depthAttachmentPixelFormat = depthFormat
    return try! device.makeRenderPipelineState(descriptor: desc)
}

// MARK: - 窗口模式（自由旋转 + 滚轮缩放 + 重置按钮 + 标题栏 FPS 与错觉状态）

class BelvedereViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var vertexCount = 0
    var yaw = magicYaw
    var pitch = magicPitch
    var halfH: Float = 3.0        // 正交视野半高（世界单位），滚轮缩放可调
    var frameCount = 0
    var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = BelvedereView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        metalView.clearColor = MTLClearColor(red: Double(paper.r), green: Double(paper.g), blue: Double(paper.b), alpha: 1)
        metalView.depthStencilPixelFormat = .depth16Unorm
        view = metalView
        let resetButton = NSButton(title: "重置", target: self, action: #selector(resetState))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.toolTip = "回到魔法角度（错觉成立视角）与默认缩放"
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        metalView.addSubview(resetButton)
        NSLayoutConstraint.activate([
            resetButton.trailingAnchor.constraint(equalTo: metalView.trailingAnchor, constant: -12),
            resetButton.topAnchor.constraint(equalTo: metalView.topAnchor, constant: 12),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? BelvedereView)?.controller = self
        queue = device.makeCommandQueue()
        pipelineState = makeBelvederePipeline(device: device,
                                              colorFormat: metalView.colorPixelFormat,
                                              depthFormat: metalView.depthStencilPixelFormat)
        let geo = makeBelvedereGeometry()
        vertexCount = geo.count
        vertexBuffer = device.makeBuffer(
            bytes: geo,
            length: geo.count * MemoryLayout<BelvedereVertex>.stride,
            options: .storageModeShared
        )
        print("Device: \(device.name)")
        print("场景：11 棱框架 + 前梁 F（近）/ 后梁 B（远），接缝错位容忍 ≈ 5°")
        print("[Pipeline ready] 正交魔法角度 · 深度测试遮挡 · 自由旋转后视差揭示两根独立短梁")
        print("拖拽：自由旋转（偏出 ±5° 即穿帮，滚轮缩放） · R 或「重置」回魔法角度")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    // 重置 = 回到错觉的"标准观测条件"：魔法角度 + 默认缩放
    @objc func resetState() {
        yaw = magicYaw
        pitch = magicPitch
        halfH = 3.0
        print("已重置：魔法角度 · 错觉成立")
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
        let light = normalize(SIMD4<Float>(0.28, 0.35, 0.89, 0))
        var u = BelvedereUniforms(
            mvp: makeMVP(yaw: yaw, pitch: pitch, aspect: Float(size.width / size.height), halfH: halfH),
            light: light
        )
        enc.setVertexBytes(&u, length: MemoryLayout<BelvedereUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<BelvedereUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
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
            view.window?.title = "Belvedere 立方体 · \(state) · FPS \(Int(fps)) · 自由旋转 滚轮缩放"
            print(String(format: "FPS ≈ %.1f（标题栏同步显示）", fps))
            frameCount = 0
            fpsWindowStart = now
        }
    }
}

class BelvedereView: MTKView {
    weak var controller: BelvedereViewController?
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
        // 自由旋转：错觉只在魔法角度附近成立，转开即断（标题栏实时提示）
        c.yaw += dYaw
        c.pitch = min(pitchLimit, max(-pitchLimit, c.pitch + dPitch))
        lastMouse = now
    }

    override func scrollWheel(with event: NSEvent) {
        guard let c = controller else { return }
        let f = exp(Float(event.scrollingDeltaY) * 0.01)
        c.halfH = min(10.0, max(1.6, c.halfH * f))
    }

    override func magnify(with event: NSEvent) {
        guard let c = controller else { return }
        c.halfH = min(10.0, max(1.6, c.halfH / Float(event.magnification)))
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller, event.charactersIgnoringModifiers == "r" else {
            super.keyDown(with: event)
            return
        }
        c.resetState()
    }
}

class BelvedereAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: BelvedereViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Belvedere 立方体 · 自由旋转 · 滚轮缩放 · R 重置"
        window.center()
        controller = BelvedereViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 离屏导出（closed = 魔法角度；open = 偏转 45° 露出两根独立短梁）

func exportBelvederePNG(path: String, open: Bool, width: Int = 1920, height: Int = 1080) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let pipeline = makeBelvederePipeline(device: device, colorFormat: .rgba8Unorm, depthFormat: .depth16Unorm)
    let geo = makeBelvedereGeometry()
    let vertexBuffer = device.makeBuffer(
        bytes: geo,
        length: geo.count * MemoryLayout<BelvedereVertex>.stride,
        options: .storageModeShared
    )!

    let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    texDesc.usage = [.renderTarget, .shaderRead]
    let texture = device.makeTexture(descriptor: texDesc)!
    let depthDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth16Unorm, width: width, height: height, mipmapped: false)
    depthDesc.usage = .renderTarget
    let depthTex = device.makeTexture(descriptor: depthDesc)!

    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = texture
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: Double(paper.r), green: Double(paper.g), blue: Double(paper.b), alpha: 1)
    rpd.depthAttachment.texture = depthTex
    rpd.depthAttachment.loadAction = .clear
    rpd.depthAttachment.storeAction = .dontCare
    rpd.depthAttachment.clearDepth = 1.0

    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    let yaw: Float = open ? magicYaw + 45.0 * Float.pi / 180 : magicYaw
    let pitch: Float = open ? magicPitch : magicPitch
    var u = BelvedereUniforms(
        mvp: makeMVP(yaw: yaw, pitch: pitch, aspect: Float(width) / Float(height), halfH: 3.0),
        light: normalize(SIMD4<Float>(0.28, 0.35, 0.89, 0))
    )
    enc.setVertexBytes(&u, length: MemoryLayout<BelvedereUniforms>.stride, index: 1)
    enc.setFragmentBytes(&u, length: MemoryLayout<BelvedereUniforms>.stride, index: 1)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geo.count)
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
    print(open ? "断口视角（偏转 45°）· 两根独立短梁  尺寸 \(width)×\(height)"
               : "闭合视角（魔法角度）· 矛盾竖梁  尺寸 \(width)×\(height)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runBelvedere() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        let open = args.count > i + 2 && args[i + 2].lowercased() == "open"
        exportBelvederePNG(path: args[i + 1], open: open)
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = BelvedereAppDelegate()
    app.delegate = delegate
    app.run()
}
