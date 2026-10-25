import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

let gameW: Float = 800
let gameH: Float = 600

// ---- 粒子数据（CPU 池管理；渲染时整块拷进顶点缓冲）----

// 送进渲染管线的实例布局（与 breakout 同款对齐模式）：中心 + 半尺寸 + 颜色，32 字节
struct FireworkInstance {
    var pos: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

// 池内完整粒子：渲染数据之外还带速度与寿命
struct Particle {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var life: Float        // 剩余寿命（秒）
    var maxLife: Float
    var color: SIMD4<Float>
    var size: Float
    var splitAt: Float     // 寿命降到该值时触发二级爆裂（<0 表示不分裂）
}

// 固定种子的 LCG：同参数导出可复现
struct LCG {
    var state: UInt32
    init(seed: UInt32) { state = seed }
    mutating func next() -> UInt32 {
        state = state &* 1664525 &+ 1013904223
        return state
    }
    mutating func unit() -> Float { Float(next() % 10000) / 10000.0 }          // 0~1
    mutating func range(_ a: Float, _ b: Float) -> Float { a + unit() * (b - a) }
}

// 粒子池：数组 + count 游标，死亡粒子用 swap-remove（与末位交换后 count-1，O(1) 无搬移）
struct ParticlePool {
    private(set) var storage: [Particle]
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = Array(repeating: Particle(pos: .zero, vel: .zero, life: 0, maxLife: 1,
                                            color: SIMD4(1, 1, 1, 1), size: 2, splitAt: -1),
                        count: capacity)
    }

    var isFull: Bool { count >= capacity }

    subscript(i: Int) -> Particle {
        get { storage[i] }
        set { storage[i] = newValue }
    }

    mutating func spawn(_ p: Particle) -> Bool {
        if isFull { return false }
        storage[count] = p
        count += 1
        return true
    }

    mutating func kill(at i: Int) {
        count -= 1
        storage.swapAt(i, count)
    }

    func instances(fadeWindow: Float) -> [FireworkInstance] {
        var out = [FireworkInstance]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let p = storage[i]
            let a = min(1.0, p.life / fadeWindow)
            out.append(FireworkInstance(pos: p.pos, size: SIMD2(p.size, p.size),
                                        color: SIMD4(p.color.x, p.color.y, p.color.z, a)))
        }
        return out
    }
}

// ---- 模拟：冲天炮 → 空中爆炸（带二级随机爆裂）----

struct FireworkSim {
    var pool = ParticlePool(capacity: 24000)
    var rockets: [(pos: SIMD2<Float>, vel: SIMD2<Float>, color: SIMD3<Float>)] = []
    var explosions = 0
    var rng = LCG(seed: 0x5EED_0001)
    let gravity: Float = -340        // px/s²
    let drag: Float = 1.1            // 线性空气阻力系数

    mutating func launch(x: Float, hueSeed: Float) {
        let vy = rng.range(430, 500)                          // y 向上发射；重力 306 下升空约 300~410px，顶点落在画面上部 1/3
        rockets.append((pos: SIMD2(x, -10),   // 世界坐标 y 向上：屏幕底是 -10，不是 gameH+10
                        vel: SIMD2(rng.range(-30, 30), vy),
                        color: SIMD3(hueSeed, hueSeed * 0.6 + 0.2, 1.0 - hueSeed * 0.5)))
    }

    // 爆炸：单发 2200 粒 + 色散 + 二级分裂标记
    mutating func explode(at pos: SIMD2<Float>, base: SIMD3<Float>) {
        let n = 2200
        for _ in 0..<n where !pool.isFull {
            let angle = rng.unit() * Float.pi * 2
            let speed = 60 + pow(rng.unit(), 0.6) * 240        // 幂次分布：外密内疏
            let disp = rng.range(0.75, 1.25)                    // 色散
            let col = SIMD4(clamp(base.x * disp, 0, 1), clamp(base.y * disp, 0, 1), clamp(base.z * disp, 0, 1), 1)
            let life = rng.range(1.2, 2.4)
            let splitAt = rng.unit() < 0.22 ? life * rng.range(0.35, 0.55) : -1
            _ = pool.spawn(Particle(pos: pos,
                                vel: speed * SIMD2(cos(angle), sin(angle)),
                                life: life, maxLife: life, color: col,
                                size: rng.range(1.5, 3.0), splitAt: splitAt))
        }
        explosions += 1
    }

    mutating func step(dt: Float) {
        // 冲天炮推进
        var i = 0
        while i < rockets.count {
            rockets[i].vel.y += gravity * 0.9 * dt
            rockets[i].pos += rockets[i].vel * dt
            // 尾焰
            _ = pool.spawn(Particle(pos: rockets[i].pos,
                                    vel: SIMD2(rng.range(-25, 25), rng.range(10, 60)),
                                    life: rng.range(0.25, 0.5), maxLife: 0.5,
                                    color: SIMD4(1.0, 0.65, 0.25, 1), size: rng.range(1.0, 2.2), splitAt: -1))
            if rockets[i].vel.y <= 30 {                         // 升到接近顶点（速度耗尽）：引爆
                explode(at: rockets[i].pos, base: rockets[i].color)
                rockets.remove(at: i)
                continue
            }
            i += 1
        }

        // 粒子：重力 + 阻力 + 寿命 + 二级爆裂；倒序遍历配合 swap-remove
        var j = 0
        while j < pool.count {
            var p = pool[j]
            p.life -= dt
            if p.life <= 0 {
                pool.kill(at: j)
                continue
            }
            p.vel.y += gravity * dt
            p.vel *= max(0, 1 - drag * dt)
            p.pos += p.vel * dt
            if p.splitAt > 0, p.life <= p.splitAt {              // 二级随机爆裂
                p.splitAt = -1
                let kids = 3 + Int(rng.unit() * 2)
                for _ in 0..<kids where !pool.isFull {
                    let angle = rng.unit() * Float.pi * 2
                    let speed = rng.range(30, 90)
                    _ = pool.spawn(Particle(pos: p.pos,
                                        vel: p.vel * 0.3 + speed * SIMD2(cos(angle), sin(angle)),
                                        life: rng.range(0.4, 0.9), maxLife: 0.9,
                                        color: SIMD4(min(p.color.x + 0.2, 1), min(p.color.y + 0.2, 1), min(p.color.z + 0.2, 1), 1),
                                        size: rng.range(1.0, 2.0), splitAt: -1))
                }
            }
            pool[j] = p
            j += 1
        }
    }
}

func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(hi, max(lo, v)) }

// ---- 渲染 ----

// 夜空背景：竖直渐变全屏四边形（普通混合，先画）
let fireworksSkySource = """
#include <metal_stdlib>
using namespace metal;

struct SkyOut {
    float4 position [[position]];
    float2 uv;
};

vertex SkyOut sky_vertex(
    const device float2 *positions [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    SkyOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = positions[vid].xy * 0.5 + 0.5;
    return out;
}

fragment float4 sky_fragment(SkyOut in [[stage_in]]) {
    return float4(mix(float3(0.015, 0.02, 0.05), float3(0.05, 0.07, 0.14), 1.0 - in.uv.y), 1.0);
}
"""

// 粒子：实例化四边形（corners + instances + res 三缓冲，breakout 同款已验证模式）+ 加法混合
let fireworksParticleSource = """
#include <metal_stdlib>
using namespace metal;

struct ParticleInstance {
    float2 pos;
    float2 size;
    float4 color;
};

struct ParticleOut {
    float4 position [[position]];
    float4 color;
};

vertex ParticleOut particle_vertex(
    const device float2 *corners [[buffer(0)]],
    const device ParticleInstance *instances [[buffer(1)]],
    constant float2 &res [[buffer(2)]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]]
) {
    ParticleInstance inst = instances[iid];
    float2 world = inst.pos + (corners[vid] - 0.5) * inst.size;
    // 实测 Metal NDC y=+1 渲染在屏幕上方——世界 y 向上直接映射，不做翻转
    ParticleOut out;
    out.position = float4(world.x / res.x * 2.0 - 1.0, world.y / res.y * 2.0 - 1.0, 0.0, 1.0);
    out.color = inst.color;
    return out;
}

fragment float4 particle_fragment(ParticleOut in [[stage_in]]) {
    return in.color;
}
"""

let fireworkQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

// 单元四边形角点（0~1），实例化渲染用
let fireworksCorners: [SIMD2<Float>] = [
    SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1),
    SIMD2(0, 1), SIMD2(1, 0), SIMD2(1, 1),
]

func makeFireworkRenderPipelines(device: MTLDevice, colorFormat: MTLPixelFormat)
    -> (skyPS: MTLRenderPipelineState, particlePS: MTLRenderPipelineState) {
    let skyLib = try! device.makeLibrary(source: fireworksSkySource, options: nil)
    let skyDesc = MTLRenderPipelineDescriptor()
    skyDesc.vertexFunction = skyLib.makeFunction(name: "sky_vertex")
    skyDesc.fragmentFunction = skyLib.makeFunction(name: "sky_fragment")
    skyDesc.colorAttachments[0].pixelFormat = colorFormat
    let skyPS = try! device.makeRenderPipelineState(descriptor: skyDesc)

    let pLib = try! device.makeLibrary(source: fireworksParticleSource, options: nil)
    let pDesc = MTLRenderPipelineDescriptor()
    pDesc.vertexFunction = pLib.makeFunction(name: "particle_vertex")
    pDesc.fragmentFunction = pLib.makeFunction(name: "particle_fragment")
    pDesc.colorAttachments[0].pixelFormat = colorFormat
    pDesc.colorAttachments[0].isBlendingEnabled = true
    pDesc.colorAttachments[0].rgbBlendOperation = .add
    pDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    pDesc.colorAttachments[0].destinationRGBBlendFactor = .one
    let particlePS = try! device.makeRenderPipelineState(descriptor: pDesc)
    return (skyPS, particlePS)
}

// MARK: - 窗口模式

class FireworksViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var skyPS: MTLRenderPipelineState!
    var particlePS: MTLRenderPipelineState!
    var quadBuffer: MTLBuffer!
    var cornersBuffer: MTLBuffer!
    var instanceBuffer: MTLBuffer!
    var sim = FireworkSim()
    var lastTime: Double = 0
    var frameCount = 0
    var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    var hueSeed: Float = 0.15

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = FireworksView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? FireworksView)?.controller = self
        queue = device.makeCommandQueue()
        (skyPS, particlePS) = makeFireworkRenderPipelines(device: device, colorFormat: metalView.colorPixelFormat)
        quadBuffer = device.makeBuffer(bytes: fireworkQuad, length: fireworkQuad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        cornersBuffer = device.makeBuffer(bytes: fireworksCorners, length: fireworksCorners.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        instanceBuffer = device.makeBuffer(length: sim.pool.capacity * MemoryLayout<FireworkInstance>.stride, options: .storageModeShared)
        print("Device: \(device.name)")
        print("烟花：点击发射（单发 2200 粒 + 二级爆裂）· 粒子池上限 \(sim.pool.capacity)")
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

        let instances = sim.pool.instances(fadeWindow: 0.6)
        if !instances.isEmpty {
            instanceBuffer.contents().copyMemory(from: instances, byteCount: instances.count * MemoryLayout<FireworkInstance>.stride)
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(skyPS)
        enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fireworkQuad.count)
        if !instances.isEmpty {
            var res = SIMD2(gameW, gameH)   // 世界坐标是 800×600 逻辑空间；传 drawableSize 会把场景压进窗口一角
            enc.setRenderPipelineState(particlePS)
            enc.setVertexBuffer(cornersBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
            enc.setVertexBytes(&res, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
        }
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        frameCount += 1
        let elapsed = now - fpsWindowStart
        if elapsed >= 2.0 {
            let fps = Double(frameCount) / elapsed
            view.window?.title = String(format: "烟花 · FPS %.0f · 池内 %d 粒 · 已发射 %d 发", fps, sim.pool.count, sim.explosions)
            print(String(format: "FPS ≈ %.1f · 池内 %d 粒", fps, sim.pool.count))
            frameCount = 0
            fpsWindowStart = now
        }
    }
}

class FireworksView: MTKView {
    weak var controller: FireworksViewController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        let b = bounds
        c.hueSeed = (c.hueSeed + 0.21).truncatingRemainder(dividingBy: 1.0)
        c.sim.launch(x: Float(p.x / b.width) * 800, hueSeed: c.hueSeed)
        print("发射 → x=\(Int(Float(p.x / b.width) * 800))")
    }
}

class FireworksAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: FireworksViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "烟花 · 点击发射"
        window.center()
        controller = FireworksViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 离屏导出（固定 seed：发射 → 定格在爆炸后 0.6s 的帧）

func exportFireworksPNG(path: String, width: Int = 800, height: Int = 600) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let (skyPS, particlePS) = makeFireworkRenderPipelines(device: device, colorFormat: .rgba8Unorm)
    let quadBuffer = device.makeBuffer(bytes: fireworkQuad, length: fireworkQuad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
    var sim = FireworkSim()
    sim.rng = LCG(seed: 42)
    if ProcessInfo.processInfo.environment["DEBUG_STATIC"] != nil {
        // 对照实验：200 个零初速粒子静置，验证重力方向
        for _ in 0..<200 {
            sim.pool.spawn(Particle(pos: SIMD2(400, 300), vel: SIMD2(0, 0), life: 5, maxLife: 5,
                                    color: SIMD4(1, 1, 1, 1), size: 2, splitAt: -1))
        }
    } else {
        sim.launch(x: 400, hueSeed: 0.3)
    }
    let dt: Float = 1.0 / 60.0
    var elapsed: Float = 0
    let freeze = ProcessInfo.processInfo.environment["FREEZE"].flatMap(Float.init) ?? 2.2
    while elapsed < freeze {          // 升空约 1.5s + 爆炸后约 0.7s，定格在拖尾下坠最明显处
        sim.step(dt: dt)
        elapsed += dt
    }
    let instances = sim.pool.instances(fadeWindow: 0.6)
    let cornersBuffer = device.makeBuffer(bytes: fireworksCorners, length: fireworksCorners.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
    let instanceBuffer = device.makeBuffer(bytes: instances, length: max(instances.count, 1) * MemoryLayout<FireworkInstance>.stride, options: .storageModeShared)

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
    if ProcessInfo.processInfo.environment["NO_SKY"] == nil {
        enc.setRenderPipelineState(skyPS)
        enc.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fireworkQuad.count)
    }
    if !instances.isEmpty {
        var res = SIMD2(Float(width), Float(height))
        enc.setRenderPipelineState(particlePS)
        enc.setVertexBuffer(cornersBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
        enc.setVertexBytes(&res, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
    }
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
    let bt0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<60 { sim.step(dt: dt) }
    let simMs = (CFAbsoluteTimeGetCurrent() - bt0) * 1000 / 60
    print("爆炸 \(sim.explosions) 发 · 定格时池内 \(sim.pool.count) 粒 · 满池模拟每帧 \(String(format: "%.2f", simMs)) ms（预算 16.6）  尺寸 \(width)×\(height)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runFireworks() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        exportFireworksPNG(path: args[i + 1])
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = FireworksAppDelegate()
    app.delegate = delegate
    app.run()
}
