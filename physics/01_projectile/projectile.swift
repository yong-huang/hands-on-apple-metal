import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - 物理模型（全部 SI 单位：米、秒、千克）
// 状态向量 [x, y, vx, vy]，二阶龙格-库塔不够看时上的就是这把 RK4 牛刀：
// 每步 4 次求导加权平均，局部误差 O(dt^5)，dt=1e-3 s 下全程能量漂移可忽略。
// 二次空气阻力 F = -c·|v|·v（c 单位 kg/m，含 ρ·Cd·A 的效果），c=0 即真空。
struct LaunchParams {
    var v0: Double = 30.0        // 初速 m/s
    var angleDeg: Double = 45.0  // 射角（度）
    var dragC: Double = 0.005    // 阻力系数 kg/m
    var mass: Double = 0.5       // 弹丸质量 kg
    var g: Double = 9.81         // 重力加速度 m/s²

    var angleRad: Double { angleDeg * .pi / 180 }
    // 真空射程解析解：R = v0²·sin(2θ)/g —— 本实验的"教科书对照基准"
    var vacuumRange: Double { v0 * v0 * sin(2 * angleRad) / g }
}

func accel(vx: Double, vy: Double, p: LaunchParams) -> SIMD2<Double> {
    let speed = (vx * vx + vy * vy).squareRoot()
    return SIMD2(-p.dragC * speed * vx / p.mass,
                 -p.g - p.dragC * speed * vy / p.mass)
}

func rk4Step(_ s: SIMD4<Double>, dt: Double, p: LaunchParams) -> SIMD4<Double> {
    func f(_ s: SIMD4<Double>) -> SIMD4<Double> {
        let a = accel(vx: s[2], vy: s[3], p: p)
        return SIMD4(s[2], s[3], a.x, a.y)   // d/dt [x,y,vx,vy] = [vx,vy,ax,ay]
    }
    let k1 = f(s)
    let k2 = f(s + 0.5 * dt * k1)
    let k3 = f(s + 0.5 * dt * k2)
    let k4 = f(s + dt * k3)
    return s + (dt / 6) * (k1 + 2 * k2 + 2 * k3 + k4)
}

struct Trajectory {
    var range: Double          // 落点射程 m（线性插值到 y=0，不是最后一步的粗值）
    var flightTime: Double     // 飞行时间 s
    var maxHeight: Double      // 最大高度 m
    var points: [SIMD2<Float>] // 渲染折线（世界坐标，米）
    var vels: [SIMD2<Float>]   // 与 points 逐点对应的速度 (m/s)，速度矢量图层用
}

// 积分到落地：y 过零时用最后一步首尾线性插值找精确落点。
// 样本间隔固定 0.02 s，sampleAt(t) 按 O(1) 索引取状态。
func simulate(_ p: LaunchParams, dt: Double = 1e-3, sampleEvery: Int = 20) -> Trajectory {
    var s = SIMD4(0.0, 0.0, p.v0 * cos(p.angleRad), p.v0 * sin(p.angleRad))
    var t = 0.0, hMax = 0.0, sample = 0
    var pts: [SIMD2<Float>] = [SIMD2(0, 0)], vels: [SIMD2<Float>] = [SIMD2(Float(s[2]), Float(s[3]))]
    while t < 500 {
        let prev = s
        s = rk4Step(s, dt: dt, p: p)
        t += dt
        hMax = max(hMax, s[1])
        sample += 1
        if sample % sampleEvery == 0 {
            pts.append(SIMD2(Float(s[0]), Float(s[1])))
            vels.append(SIMD2(Float(s[2]), Float(s[3])))
        }
        if s[1] < 0 {
            let f = prev[1] / (prev[1] - s[1])
            let xLand = prev[0] + f * (s[0] - prev[0])
            pts.append(SIMD2(Float(xLand), 0))
            vels.append(SIMD2(Float(s[2]), Float(s[3])))
            return Trajectory(range: xLand, flightTime: t - dt + f * dt, maxHeight: hMax,
                              points: pts, vels: vels)
        }
    }
    fatalError("积分 500 s 未落地：参数非法（角度 ≤0°？）")
}

// 取 t 时刻的采样状态（样本间隔 0.02 s）
func sampleAt(_ tr: Trajectory, _ t: Double) -> (pos: SIMD2<Float>, vel: SIMD2<Float>) {
    let idx = min(Int(t / 0.02), tr.points.count - 1)
    return (tr.points[idx], tr.vels[idx])
}

// MARK: - 定量验收：模拟值 vs 教科书公式对照表
// vacuumRange 是解析解，阻力最优射角无闭式解——用 0.25° 步进扫掠找数值最优，
// 断言只盯两条硬指标：真空误差 <1%、阻力最优角 <45° 且随 c 单调前移。
@discardableResult
func verifyProjectile() -> Bool {
    print("==== 抛体验证（RK4 dt=1e-3 s，v0=30 m/s，m=0.5 kg，g=9.81 m/s²）====")
    var pass = 0, total = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        total += 1
        if ok { pass += 1 }
        print("[\(ok ? "PASS" : "FAIL")] \(name)：\(detail)")
    }

    // ① 真空五组射角：模拟射程 vs R = v0²sin(2θ)/g
    for ang in [20.0, 30.0, 40.0, 45.0, 60.0] {
        var p = LaunchParams(); p.angleDeg = ang; p.dragC = 0
        let r = simulate(p).range
        let err = abs(r - p.vacuumRange) / p.vacuumRange * 100
        check("真空 θ=\(Int(ang))° 射程", err < 1.0,
              String(format: "模拟 %.3f m | 理论 %.3f m | 误差 %.4f%%", r, p.vacuumRange, err))
    }

    // ② 真空最优射角 = 45°（扫掠 5°~85°）
    func bestAngle(_ p: LaunchParams) -> Double {
        var best = (angle: 5.0, range: 0.0)
        var ang = 5.0
        while ang <= 85 {
            var q = p; q.angleDeg = ang
            let r = simulate(q, dt: 2e-3).range
            if r > best.range { best = (ang, r) }
            ang += 0.25
        }
        return best.angle
    }
    var vacP = LaunchParams(); vacP.dragC = 0
    let vacBest = bestAngle(vacP)
    check("真空最优射角", abs(vacBest - 45.0) <= 0.25 + 1e-9,
          String(format: "扫掠最优 θ* = %.2f°（理论 45.00°）", vacBest))

    // ③ 阻力最优射角 < 45°，且随 c 增大前移
    var bests: [Double] = []
    for c in [0.002, 0.005, 0.010] {
        var p = LaunchParams(); p.dragC = c
        let b = bestAngle(p)
        bests.append(b)
        check("阻力 c=\(c) kg/m 最优射角", b < 45.0,
              String(format: "扫掠最优 θ* = %.2f°（< 45°）", b))
    }
    check("最优角随 c 单调前移", zip(bests, bests.dropFirst()).allSatisfy({ $1 < $0 }),
          zip(bests, [0.002, 0.005, 0.010]).map { String(format: "c=%.3f→%.2f°", $1, $0) }.joined(separator: "，"))

    // ④ 同参数下阻力缩短射程（物理常识兜底，防止阻力写反号还侥幸过前面）
    let dragP = LaunchParams()
    let drg = simulate(dragP).range
    var vacQ = dragP; vacQ.dragC = 0
    let vacRange = simulate(vacQ).range
    check("阻力缩短射程", drg < vacRange * 0.99,
          String(format: "θ=45°：真空 %.2f m → 阻力 %.2f m（-%.1f%%）",
                 vacRange, drg, (1 - drg / vacRange) * 100))

    print("==== 验收结果：\(pass)/\(total) PASS ====")
    return pass == total
}

// MARK: - 着色器（内嵌源码，运行时编译）：世界坐标(米) → NDC 的线段渲染
let projectileShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct LineUniforms { float4 scaleOffset; };   // xy=等比缩放 zw=平移

vertex float4 vertex_line(const device float2 *verts [[buffer(0)]],
                          constant LineUniforms &u [[buffer(1)]],
                          uint vid [[vertex_id]]) {
    float2 p = verts[vid] * u.scaleOffset.xy + u.scaleOffset.zw;
    return float4(p, 0.0, 1.0);
}

fragment float4 fragment_line(constant float4 &color [[buffer(2)]]) {
    return color;
}
"""

struct LineUniforms { var scaleOffset: SIMD4<Float> }

// 一次场景的全部顶点与视野：窗口渲染与离屏导出共用同一份几何
struct SceneGeometry {
    var decor: [SIMD2<Float>]      // 地面 + 刻度 + 落点标记
    var markers: [SIMD2<Float>]    // 等时标记：每 0.5 s 连线 + 小十字
    var vacuum: [SIMD2<Float>]     // 真空轨迹折线
    var drag: [SIMD2<Float>]       // 阻力轨迹折线
    var vacArrows: [SIMD2<Float>]  // 速度矢量（真空）
    var dragArrows: [SIMD2<Float>] // 速度矢量（阻力）
    var uniforms: LineUniforms

    static func build(vac: Trajectory, drg: Trajectory) -> SceneGeometry {
        // 等比缩放：画面装下两条轨迹的公共世界框，垂直方向居中（地面不钉死在底边）
        let worldW = max(vac.range, drg.range) * 1.06 + 2
        let worldH = max(6.0, max(vac.maxHeight, drg.maxHeight) * 1.35)
        let s = Float(min(1.88 / worldW, 1.66 / worldH))
        let ySpan = Float(worldH) * s
        let y0: Float = -1.0 + (2.0 - ySpan) * 0.5 + 0.08   // 底边留 0.08 给地面刻度
        let uniforms = LineUniforms(scaleOffset: SIMD4(s, s, -0.94, y0))

        var decor: [SIMD2<Float>] = []
        decor += [SIMD2(-1, 0), SIMD2(Float(worldW), 0)]                  // 地面
        var x = 10.0                                                      // 每 10 m 一根刻度
        while x < worldW { decor += [SIMD2(Float(x), -0.35), SIMD2(Float(x), 0)]; x += 10 }
        decor += [SIMD2(0, 0.5), SIMD2(0, -0.35)]                         // 发射点小竖线
        decor += [SIMD2(Float(vac.range), 0.5), SIMD2(Float(vac.range), -0.35)]  // 两条落点标记
        decor += [SIMD2(Float(drg.range), 0.5), SIMD2(Float(drg.range), -0.35)]

        // 等时标记：每 0.5 s 一对小十字（真空白/阻力橙各一）——同刻横向间距即被空气拉开的差距。
        // 不画两点连线：Metal 线段无虚线，长直线会像第三条轨迹
        var markers: [SIMD2<Float>] = []
        let tEnd = min(vac.flightTime, drg.flightTime) - 0.01
        var mt = 0.5
        while mt < tEnd {
            for tr in [vac, drg] {
                let p = sampleAt(tr, mt).pos
                markers += [p + SIMD2(-0.8, 0), p + SIMD2(0.8, 0)]
                markers += [p + SIMD2(0, -0.8), p + SIMD2(0, 0.8)]
            }
            mt += 0.5
        }

        // 速度矢量：飞行 30%/60%/85% 时刻，箭杆 = 0.4 s 内的位移，箭头 = 转 ±25° 的两条短线
        func arrow(_ out: inout [SIMD2<Float>], _ st: (pos: SIMD2<Float>, vel: SIMD2<Float>)) {
            let len = simd_length(st.vel)
            guard len > 1e-4 else { return }
            let dir = st.vel / len
            let tip = st.pos + st.vel * 0.4
            out += [st.pos, tip]
            for sign in [1.0, -1.0] {
                let th = Float(sign) * 25.0 * .pi / 180
                let back = -SIMD2(dir.x * cos(th) - dir.y * sin(th),
                                  dir.x * sin(th) + dir.y * cos(th)) * 2.6
                out += [tip, tip + back]
            }
        }
        var vacArrows: [SIMD2<Float>] = [], dragArrows: [SIMD2<Float>] = []
        for f in [0.3, 0.6, 0.85] {
            arrow(&vacArrows, sampleAt(vac, vac.flightTime * f))
            arrow(&dragArrows, sampleAt(drg, drg.flightTime * f))
        }
        return SceneGeometry(decor: decor, markers: markers, vacuum: vac.points, drag: drg.points,
                             vacArrows: vacArrows, dragArrows: dragArrows, uniforms: uniforms)
    }
}

// MARK: - 窗口模式（MTKView）：同一发射参数画两条轨迹，白=真空 橙=阻力
class ProjectileViewController: NSViewController, MTKViewDelegate {
    let dragLevels: [Double] = [0.002, 0.005, 0.010]
    var dragIndex = 1
    var params = LaunchParams()

    var metalView: MTKView!
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var decorBuffer: MTLBuffer!     // 地面 + 10 m 刻度 + 落点标记
    var vacuumBuffer: MTLBuffer!    // 真空轨迹折线
    var dragBuffer: MTLBuffer!      // 阻力轨迹折线
    var markerBuffer: MTLBuffer!    // 等时标记：每 0.5 s 的连线 + 小十字
    var vacArrowBuffer: MTLBuffer!  // 真空轨迹的速度矢量
    var dragArrowBuffer: MTLBuffer! // 阻力轨迹的速度矢量
    var decorCount = 0, vacuumCount = 0, dragCount = 0
    var markerCount = 0, vacArrowCount = 0, dragArrowCount = 0
    var uniforms = LineUniforms(scaleOffset: .init(1, 1, -0.94, -0.86))

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("本机不支持 Metal") }
        self.device = device
        metalView = ProjectileView(frame: NSRect(x: 0, y: 0, width: 960, height: 600), device: device)
        metalView.delegate = self
        metalView.clearColor = MTLClearColor(red: 0.043, green: 0.051, blue: 0.075, alpha: 1)
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? ProjectileView)?.controller = self
        commandQueue = device.makeCommandQueue()
        let desc = MTLRenderPipelineDescriptor()
        let library = try! device.makeLibrary(source: projectileShaderSource, options: nil)
        desc.vertexFunction = library.makeFunction(name: "vertex_line")
        desc.fragmentFunction = library.makeFunction(name: "fragment_line")
        desc.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        pipelineState = try! device.makeRenderPipelineState(descriptor: desc)
        print("Device: \(device.name)")
        print("[Pipeline ready] vertex_line + fragment_line")
        resimulate()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
        resimulate()   // 此时 window 已挂上，把动态参数写进窗口标题
    }

    // 重算两条轨迹并重建顶点缓冲（CPU RK4 三千步，微秒级，随便每次按键都算）
    func resimulate() {
        var vacP = params; vacP.dragC = 0
        let vac = simulate(vacP)
        let drg = simulate(params)
        let geo = SceneGeometry.build(vac: vac, drg: drg)
        uniforms = geo.uniforms

        func fill(_ verts: [SIMD2<Float>]) -> (MTLBuffer, Int) {
            let buf = device.makeBuffer(bytes: verts,
                                        length: max(verts.count, 1) * MemoryLayout<SIMD2<Float>>.stride,
                                        options: .storageModeShared)!
            return (buf, verts.count)
        }
        (decorBuffer, decorCount) = fill(geo.decor)
        (vacuumBuffer, vacuumCount) = fill(geo.vacuum)
        (dragBuffer, dragCount) = fill(geo.drag)
        (markerBuffer, markerCount) = fill(geo.markers)
        (vacArrowBuffer, vacArrowCount) = fill(geo.vacArrows)
        (dragArrowBuffer, dragArrowCount) = fill(geo.dragArrows)

        let loss = (1 - drg.range / vac.range) * 100
        view.window?.title = String(format: "抛体运动 v0=%.0f m/s θ=%.0f° c=%.3f kg/m ｜ 真空 %.1f m / 阻力 %.1f m（-%.0f%%）",
                                    params.v0, params.angleDeg, params.dragC, vac.range, drg.range, loss)
    }

    func drawLine(_ enc: MTLRenderCommandEncoder, buffer: MTLBuffer, count: Int,
                  type: MTLPrimitiveType, color: SIMD4<Float>) {
        var color = color
        enc.setRenderPipelineState(pipelineState)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<LineUniforms>.stride, index: 1)
        enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        enc.drawPrimitives(type: type, vertexStart: 0, vertexCount: count)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = metalView.currentDrawable,
              let rpd = metalView.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        drawLine(enc, buffer: decorBuffer, count: decorCount, type: .line,
                 color: SIMD4(0.45, 0.47, 0.52, 1))
        drawLine(enc, buffer: markerBuffer, count: markerCount, type: .line,
                 color: SIMD4(0.30, 0.32, 0.36, 1))
        drawLine(enc, buffer: vacuumBuffer, count: vacuumCount, type: .lineStrip,
                 color: SIMD4(0.82, 0.85, 0.90, 1))
        drawLine(enc, buffer: dragBuffer, count: dragCount, type: .lineStrip,
                 color: SIMD4(1.0, 0.55, 0.15, 1))
        drawLine(enc, buffer: vacArrowBuffer, count: vacArrowCount, type: .line,
                 color: SIMD4(0.82, 0.85, 0.90, 1))
        drawLine(enc, buffer: dragArrowBuffer, count: dragArrowCount, type: .line,
                 color: SIMD4(1.0, 0.55, 0.15, 1))
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    // MARK: 交互：←→ 调初速，↑↓ 调射角，D 轮换阻力，R 重置，T 打印对照表
    func adjust(_ body: (inout LaunchParams) -> Void) {
        body(&params)
        resimulate()
        let vac = simulate({ var q = params; q.dragC = 0; return q }())
        let drg = simulate(params)
        print(String(format: "v0=%.0f m/s θ=%.0f° c=%.3f kg/m → 真空 %.1f m（飞行 %.2f s）/ 阻力 %.1f m（飞行 %.2f s）",
                     params.v0, params.angleDeg, params.dragC, vac.range, vac.flightTime, drg.range, drg.flightTime))
    }
}

class ProjectileView: MTKView {
    weak var controller: ProjectileViewController?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let controller else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123: controller.adjust { $0.v0 = max(5, $0.v0 - 1) }              // ←
        case 124: controller.adjust { $0.v0 = min(80, $0.v0 + 1) }             // →
        case 126: controller.adjust { $0.angleDeg = min(85, $0.angleDeg + 1) } // ↑
        case 125: controller.adjust { $0.angleDeg = max(5, $0.angleDeg - 1) }  // ↓
        case 2:                                                                // D
            controller.dragIndex = (controller.dragIndex + 1) % controller.dragLevels.count
            controller.adjust { $0.dragC = controller.dragLevels[controller.dragIndex] }
        case 15:                                                               // R
            controller.dragIndex = 1
            controller.adjust { $0 = LaunchParams() }
        case 17: verifyProjectile()                                            // T
        default: super.keyDown(with: event)
        }
    }
}

class ProjectileAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "抛体运动（←→ 初速 ↑↓ 射角 D 阻力 T 对照表 R 重置）｜ 小十字 = 每 0.5 s 等时点，箭头 = 速度"
        window.center()
        window.contentViewController = ProjectileViewController()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 离屏导出（不开窗口：渲一帧写 PNG，无人值守验收与视觉核对用）
func exportScenePNG(path: String, width: Int = 1440, height: Int = 900) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    var vacP = LaunchParams(); vacP.dragC = 0
    let geo = SceneGeometry.build(vac: simulate(vacP), drg: simulate(LaunchParams()))
    let library = try! device.makeLibrary(source: projectileShaderSource, options: nil)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "vertex_line")
    desc.fragmentFunction = library.makeFunction(name: "fragment_line")
    desc.colorAttachments[0].pixelFormat = .rgba8Unorm
    let pipeline = try! device.makeRenderPipelineState(descriptor: desc)

    func fill(_ verts: [SIMD2<Float>]) -> MTLBuffer {
        device.makeBuffer(bytes: verts,
                          length: max(verts.count, 1) * MemoryLayout<SIMD2<Float>>.stride,
                          options: .storageModeShared)!
    }
    let buffers = [fill(geo.decor), fill(geo.markers), fill(geo.vacuum),
                   fill(geo.drag), fill(geo.vacArrows), fill(geo.dragArrows)]
    let counts = [geo.decor.count, geo.markers.count, geo.vacuum.count,
                  geo.drag.count, geo.vacArrows.count, geo.dragArrows.count]
    let types: [MTLPrimitiveType] = [.line, .line, .lineStrip, .lineStrip, .line, .line]
    let colors: [SIMD4<Float>] = [
        SIMD4(0.45, 0.47, 0.52, 1), SIMD4(0.30, 0.32, 0.36, 1),
        SIMD4(0.82, 0.85, 0.90, 1), SIMD4(1.0, 0.55, 0.15, 1),
        SIMD4(0.82, 0.85, 0.90, 1), SIMD4(1.0, 0.55, 0.15, 1)]

    let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                           width: width, height: height, mipmapped: false)
    texDesc.usage = [.renderTarget, .shaderRead]
    let texture = device.makeTexture(descriptor: texDesc)!
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = texture
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.043, green: 0.051, blue: 0.075, alpha: 1)

    var u = geo.uniforms
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    for i in 0..<6 {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buffers[i], offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<LineUniforms>.stride, index: 1)
        var color = colors[i]
        enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        enc.drawPrimitives(type: types[i], vertexStart: 0, vertexCount: counts[i])
    }
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
    guard CGImageDestinationFinalize(dest) else { fatalError("PNG 写出失败：\(path)") }
    print("✅ PNG 已写出：\(path)（\(width)×\(height)）")
}

// MARK: - 入口：`projectile verify` 无窗口跑定量验收（脚本用），`export` 出 PNG，默认开窗口交互
func runProjectile() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        exportScenePNG(path: args[i + 1])
        exit(0)
    }
    if args.contains("verify") {
        exit(verifyProjectile() ? 0 : 1)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包命令行进程不设 regular 窗口不显示
    let delegate = ProjectileAppDelegate()   // NSApplication.delegate 是弱引用，须留强引用
    app.delegate = delegate
    app.run()
}
