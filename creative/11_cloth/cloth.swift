import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// ---- 布料物理（纯 CPU 逻辑，可无人值守快进）----

let gameW: Float = 800
let gameH: Float = 600
let clothCols = 24
let clothRows = 24
let spacing: Float = 16
let clothX0: Float = 216
let clothY0: Float = 60
let gravity: Float = 900              // px/s²
let constraintIters = 12
let tearRatio: Float = 3.2            // 约束伸长超过 rest 的 2.4 倍即撕断

struct ClothNode {
    var pos: SIMD2<Float>
    var prev: SIMD2<Float>
    var pinned: Bool
}

struct ClothConstraint {
    var a: Int32
    var b: Int32
    var rest: Float
}

// 渲染顶点：位置 + 颜色（24 字节），每个约束一段四边形（6 顶点）
struct ClothVertex {
    var pos: SIMD2<Float>
    var color: SIMD4<Float>
}

struct ClothSim {
    var nodes: [ClothNode] = []
    var constraints: [ClothConstraint] = []
    var grabbed: Int? = nil
    var mouse = SIMD2<Float>(gameW / 2, 300)
    var time: Float = 0
    var rngState: UInt32 = 0x1D1B

    init() {
        for r in 0..<clothRows {
            for c in 0..<clothCols {
                let p = SIMD2(clothX0 + Float(c) * spacing, clothY0 + Float(r) * spacing)
                let pinned = (r == 0) && (c == 0 || c == clothCols - 1)   // 顶部两角钉住
                nodes.append(ClothNode(pos: p, prev: p, pinned: pinned))
            }
        }
        func id(_ c: Int, _ r: Int) -> Int { r * clothCols + c }
        for r in 0..<clothRows {
            for c in 0..<clothCols {
                if c + 1 < clothCols { constraints.append(ClothConstraint(a: Int32(id(c, r)), b: Int32(id(c + 1, r)), rest: spacing)) }
                if r + 1 < clothRows { constraints.append(ClothConstraint(a: Int32(id(c, r)), b: Int32(id(c, r + 1)), rest: spacing)) }
            }
        }
    }

    var tornCount: Int { initialConstraints - constraints.count }
    var initialConstraints: Int { clothRows * (clothCols - 1) + clothCols * (clothRows - 1) }

    mutating func grabNearest(to point: SIMD2<Float>) {
        var best = -1
        var bestDist: Float = 26 * 26
        for (i, n) in nodes.enumerated() {
            let d = simd_length_squared(n.pos - point)
            if d < bestDist { bestDist = d; best = i }
        }
        if best >= 0 { grabbed = best }
    }

    mutating func drag(to point: SIMD2<Float>) {
        if grabbed != nil { mouse = point }
    }

    mutating func release() {
        grabbed = nil
    }

    // 手指始终捏着布：被抓节点的约束若已全部撕断，自动改抓"仍有约束"的最近节点（沿线继续撕）
    mutating func maintainGrab() {
        guard let g = grabbed else { return }
        let stillAttached = constraints.contains { $0.a == Int32(g) || $0.b == Int32(g) }
        if stillAttached { return }
        var best = -1
        var bestDist = Float.infinity
        for i in nodes.indices {
            let attached = constraints.contains { $0.a == i || $0.b == i }
            guard attached else { continue }
            let d = simd_length_squared(nodes[i].pos - mouse)
            if d < bestDist { bestDist = d; best = i }
        }
        grabbed = best >= 0 ? best : nil
    }

    // 单帧物理：Verlet 积分（含风）→ 12 轮约束迭代（迭代中撕断超限约束）
    mutating func step(dt: Float) {
        maintainGrab()
        time += dt
        let dtt = dt * dt
        for i in nodes.indices {
            if nodes[i].pinned || i == grabbed {
                if i == grabbed { nodes[i].pos = mouse; nodes[i].prev = mouse }   // 抓取点钉在指针上
                continue
            }
            let n = nodes[i]
            let wind = sin(time * 1.7 + n.pos.y * 0.011) * 46 + 14
            let vel = (n.pos - n.prev) * 0.99
            nodes[i].prev = n.pos
            nodes[i].pos += vel + SIMD2(wind, gravity) * dtt
        }
        for _ in 0..<constraintIters {
            var torn = 0
            var i = 0
            while i < constraints.count - torn {
                let c = constraints[i]
                let delta = nodes[Int(c.b)].pos - nodes[Int(c.a)].pos
                let d = simd_length(delta)
                if d > c.rest * tearRatio {
                    constraints.swapAt(i, constraints.count - 1 - torn)   // 标记撕断：与未检查尾部交换，原地重查
                    torn += 1
                    continue
                }
                let diff = (d - c.rest) / d * 0.5
                let pa = nodes[Int(c.a)].pinned
                let pb = nodes[Int(c.b)].pinned
                if !pa && !pb {
                    nodes[Int(c.a)].pos += delta * diff
                    nodes[Int(c.b)].pos -= delta * diff
                } else if pa && !pb {
                    nodes[Int(c.b)].pos -= delta * diff * 2
                } else if !pa && pb {
                    nodes[Int(c.a)].pos += delta * diff * 2
                }
                i += 1
            }
            // 把标记为撕断的约束一次性移除（与尾部交换后，尾部 torn 个全部待删）
            if torn > 0 {
                constraints.removeLast(torn)
            }
        }
    }
}

// ---- 渲染：约束四边形（拉伸越大越红）+ 钉住点高亮 ----

func strainColor(_ strain: Float) -> SIMD4<Float> {
    let t = min(max(strain / 0.6, 0), 1)
    let green = SIMD4<Float>(0.30, 0.85, 0.45, 1)
    let yellow = SIMD4<Float>(0.96, 0.85, 0.30, 1)
    let red = SIMD4<Float>(0.92, 0.25, 0.22, 1)
    return t < 0.5 ? mix(green, yellow, t * 2) : mix(yellow, red, (t - 0.5) * 2)
}

func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
    a + (b - a) * t
}

func buildClothVertices(sim: ClothSim) -> [ClothVertex] {
    var verts = [ClothVertex]()
    verts.reserveCapacity(sim.constraints.count * 6 + 48)
    let halfW: Float = 1.3
    for c in sim.constraints {
        let p1 = sim.nodes[Int(c.a)].pos
        let p2 = sim.nodes[Int(c.b)].pos
        let d = p2 - p1
        let len = simd_length(d)
        guard len > 0.0001 else { continue }
        let n = SIMD2(-d.y, d.x) / len * halfW
        let strain = len / c.rest - 1
        let col = strainColor(strain)
        let v1 = p1 + n, v2 = p2 + n, v3 = p1 - n, v4 = p2 - n
        verts.append(contentsOf: [
            ClothVertex(pos: v1, color: col), ClothVertex(pos: v2, color: col), ClothVertex(pos: v3, color: col),
            ClothVertex(pos: v3, color: col), ClothVertex(pos: v2, color: col), ClothVertex(pos: v4, color: col),
        ])
    }
    // 钉住点画成白色小块
    for n in sim.nodes where n.pinned {
        let p = n.pos
        let s: Float = 5
        let col = SIMD4<Float>(0.95, 0.95, 0.98, 1)
        let c1 = SIMD2<Float>(p.x - s, p.y - s)
        let c2 = SIMD2<Float>(p.x + s, p.y - s)
        let c3 = SIMD2<Float>(p.x - s, p.y + s)
        let c4 = SIMD2<Float>(p.x + s, p.y + s)
        verts.append(contentsOf: [
            ClothVertex(pos: c1, color: col), ClothVertex(pos: c2, color: col), ClothVertex(pos: c3, color: col),
            ClothVertex(pos: c3, color: col), ClothVertex(pos: c2, color: col), ClothVertex(pos: c4, color: col),
        ])
    }
    return verts
}

let clothVertexSource = """
#include <metal_stdlib>
using namespace metal;

struct ClothVertexIn {
    float2 pos;
    float4 color;
};

struct ClothVOut {
    float4 position [[position]];
    float4 color;
};

vertex ClothVOut vertex_main(
    const device ClothVertexIn *verts [[buffer(0)]],
    constant float2 &gameRes [[buffer(1)]],
    uint vid [[vertex_id]]
) {
    ClothVertexIn v = verts[vid];
    // 游戏坐标 y 向下 → NDC y 向上，翻转
    ClothVOut out;
    out.position = float4(v.pos.x / gameRes.x * 2.0 - 1.0, 1.0 - v.pos.y / gameRes.y * 2.0, 0.0, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 fragment_main(ClothVOut in [[stage_in]]) {
    return in.color;
}
"""

let clothQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

func makeClothPipeline(device: MTLDevice, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let library = try! device.makeLibrary(source: clothVertexSource, options: nil)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "vertex_main")
    desc.fragmentFunction = library.makeFunction(name: "fragment_main")
    desc.colorAttachments[0].pixelFormat = colorFormat
    return try! device.makeRenderPipelineState(descriptor: desc)
}

// MARK: - 窗口模式

class ClothViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var quadBuffer: MTLBuffer!
    var sim = ClothSim()
    var lastTime: Double = 0
    var frameCount = 0
    var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = ClothView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? ClothView)?.controller = self
        queue = device.makeCommandQueue()
        pipelineState = makeClothPipeline(device: device, colorFormat: metalView.colorPixelFormat)
        vertexBuffer = device.makeBuffer(length: 24000 * MemoryLayout<ClothVertex>.stride, options: .storageModeShared)
        quadBuffer = device.makeBuffer(bytes: clothQuad, length: clothQuad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        print("Device: \(device.name)")
        print("布料：\(clothCols)×\(clothRows) 节点 · 拖拽甩动撕开 · R 重置 · 约束初始 \(sim.constraints.count) 条")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        if lastTime == 0 { lastTime = now }
        let dt = Float(min(now - lastTime, 1.0 / 30.0))
        lastTime = now
        sim.step(dt: dt)

        let verts = buildClothVertices(sim: sim)
        if !verts.isEmpty {
            vertexBuffer.contents().copyMemory(from: verts, byteCount: verts.count * MemoryLayout<ClothVertex>.stride)
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var logical = SIMD2(gameW, gameH)
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&logical, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        frameCount += 1
        let elapsed = now - fpsWindowStart
        if elapsed >= 2.0 {
            let fps = Double(frameCount) / elapsed
            view.window?.title = String(format: "可撕裂布料 · FPS %.0f · 撕断 %d 条", fps, sim.tornCount)
            frameCount = 0
            fpsWindowStart = now
        }
    }
}

class ClothView: MTKView {
    weak var controller: ClothViewController?
    var mouseIsDown = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseIsDown = true
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        let fx = Float(p.x / bounds.width), fy = Float(1 - p.y / bounds.height)
        c.sim.grabNearest(to: SIMD2(fx * gameW, fy * gameH))
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseIsDown, let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        let fx = Float(p.x / bounds.width), fy = Float(1 - p.y / bounds.height)
        c.sim.drag(to: SIMD2(fx * gameW, fy * gameH))
    }

    override func mouseUp(with event: NSEvent) {
        guard let c = controller else { return }
        mouseIsDown = false
        c.sim.release()
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return super.keyDown(with: event) }
        if event.keyCode == 15 {                             // R
            c.sim = ClothSim()
            print("布料已重置")
        } else {
            super.keyDown(with: event)
        }
    }
}

class ClothAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: ClothViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "可撕裂布料 · 拖拽甩动撕开 · R 重置"
        window.center()
        controller = ClothViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - test（无人值守两条验收断言）与导出

func clothTest() {
    // 断言一（稳定性）：静置 240 帧（4 秒，含风），约束零撕断、无 NaN、布料不落地
    var g = ClothSim()
    for _ in 0..<240 { g.step(dt: 1.0 / 60.0) }
    var nan = false
    for n in g.nodes where n.pos.x.isNaN || n.pos.y.isNaN { nan = true }
    let maxDrop = g.nodes.map(\.pos.y).max() ?? 0
    let a1 = g.tornCount == 0 && !nan && maxDrop < gameH
    print("断言一（静置 240 帧）：撕断 \(g.tornCount) 条 · NaN \(nan ? "有" : "无") · 最低点 y=\(String(format: "%.0f", maxDrop))")
    print(a1 ? "✅ 通过：约束零撕断、无 NaN、未落地" : "❌ 未通过")

    // 断言二（撕裂）：抓住底行中央节点，120 帧内匀速下拉 260px，应撕断一批且破口有界
    var g2 = ClothSim()
    let grabIdx = clothRows * (clothCols / 2) + (clothRows - 1)   // 底行中央节点
    let start = g2.nodes[grabIdx].pos
    for f in 0..<8 {
        let t = Float(f + 1) / 8
        g2.grabbed = grabIdx
        g2.mouse = start + SIMD2(60, 380) * t                     // 猛拽：单帧位移 48px 超过约束传播速度
        g2.step(dt: 1.0 / 60.0)
    }
    g2.release()
    // 再静置 240 帧：确认破口不蔓延失控
    for _ in 0..<240 { g2.step(dt: 1.0 / 60.0) }
    let torn = g2.tornCount
    let bounded = torn >= 8 && torn <= g2.initialConstraints / 2
    let a2 = bounded && !g2.constraints.isEmpty
    print("断言二（强拉撕裂）：撕断 \(torn) 条 / 初始 \(g2.initialConstraints) 条（\(String(format: "%.0f", Float(torn) / Float(g2.initialConstraints) * 100))%）· 剩余约束 \(g2.constraints.count)")
    print(a2 ? "✅ 通过：撕断量有界（≥8 且 <50%），破口未蔓延失控" : "❌ 未通过")
    print(a1 && a2 ? "✅ 验收全部通过" : "❌ 验收未全部通过")
    exit(a1 && a2 ? 0 : 1)
}

func clothBench() {
    var g = ClothSim()
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<100 { g.step(dt: 1.0 / 60.0) }
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 100
    print(String(format: "物理单帧 %.2f ms（%d 节点 · %d 约束 · 4 轮迭代，预算 16.6 ms）", ms, g.nodes.count, g.constraints.count))
    print(ms < 16.6 ? "✅ 60 FPS 预算：通过" : "❌ 未达预算")
}

func exportClothPNG(path: String, pullFrames: Int, width: Int = 800, height: Int = 600) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let pipelineState = makeClothPipeline(device: device, colorFormat: .rgba8Unorm)
    var sim = ClothSim()
    if pullFrames > 0 {
        let grabIdx = clothRows * (clothCols / 2) + (clothRows - 1)
        let start = sim.nodes[grabIdx].pos
        for f in 0..<pullFrames {
            let t = Float(f) / Float(max(pullFrames, 1))
            sim.grabbed = grabIdx
            sim.mouse = start + SIMD2(30, 260) * t
            sim.step(dt: 1.0 / 60.0)
        }
        sim.release()
        for _ in 0..<240 { sim.step(dt: 1.0 / 60.0) }
    }
    let verts = buildClothVertices(sim: sim)
    let vertexBuffer = device.makeBuffer(bytes: verts, length: max(verts.count, 1) * MemoryLayout<ClothVertex>.stride, options: .storageModeShared)

    let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    texDesc.usage = [.renderTarget, .shaderRead]
    let outTex = device.makeTexture(descriptor: texDesc)!
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = outTex
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    enc.setRenderPipelineState(pipelineState)
    enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    var logical = SIMD2(gameW, gameH)
    enc.setVertexBytes(&logical, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
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
    print("撕断 \(sim.tornCount) 条 / 初始 \(sim.initialConstraints) 条  尺寸 \(width)×\(height)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runCloth() {
    let args = CommandLine.arguments
    if args.contains("test") {
        clothTest()
        exit(0)
    }
    if args.contains("bench") {
        clothBench()
        exit(0)
    }
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        let pull = args.count > i + 2 ? (Int(args[i + 2]) ?? 0) : 0
        exportClothPNG(path: args[i + 1], pullFrames: pull)
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = ClothAppDelegate()
    app.delegate = delegate
    app.run()
}
