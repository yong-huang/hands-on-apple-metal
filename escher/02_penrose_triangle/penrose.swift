import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import simd

// 纸面底色：窗口 clear、导出 clear 共用（同 01 实验）
let paper = (r: Float(0.96), g: Float(0.95), b: Float(0.92))

// ---- 几何参数 ----
// 三角外接半径 R、梁宽 w、三片 V 形折梁的层间深度差 μ。
// 断裂角 ≈ w/D（视差位移 α·D 超过梁宽即穿帮）：w=0.55、D=10 → ≈3.1°
let triR: Float = 3.0
let beamW: Float = 0.8
let spanLevels: [Float] = [1.2, 0.6, 0.25]  // F 键循环：层间深度差——V 片 0/1/2 分层，差越小织接越"结实"
var depthSpan: Float = spanLevels[0]        // 断裂角 ≈ asin(w/2μ)：w=0.8、μ=1.2 → ≈19°
// 三片三色调（致敬原画的轮转明暗）：每片一条臂亮一半暗一半，片间跳变 = 可见织接
let pieceTones: [SIMD4<Float>] = [
    SIMD4<Float>(0.17, 0.18, 0.21, 1),   // 片 0：暗墨
    SIMD4<Float>(0.33, 0.34, 0.39, 1),   // 片 1：中调
    SIMD4<Float>(0.56, 0.58, 0.65, 1),   // 片 2：亮灰
]
let inkCap = SIMD4<Float>(0.25, 0.26, 0.30, 1)   // 角部补板：中暗

// 顶点格式：pos.xyz + nrm.xyz + color.rgb（各补 w 对齐 16 字节，与 MSL 结构体逐字段对应）
struct PenroseVertex {
    var pos: SIMD4<Float>
    var nrm: SIMD4<Float>
    var color: SIMD4<Float>
}

struct PenroseUniforms {
    var mvp: simd_float4x4
    var light: SIMD4<Float>   // xyz = 光照方向（世界系，已归一化）
}

// ---- 几何构建：三段 L 形梁，每段 = 长臂 + 转接块 + 后撤的脚 ----
// 角点 c_k 指向角 90°+120°k；piece k 的长臂沿边 (c_k → c_{k+1})、起端缩短 T（缺口），
// 远端在 c_{k+1} 处向屏幕深处折 T·D，沿下一条边方向伸出 2T——魔法角度下恰好
// 填补 piece k+1 的起端缺口并藏在其后方（"每根梁都从下一根的后面绕出来" = 不可能解读）

func boxInto(_ out: inout [PenroseVertex], center: SIMD3<Float>,
             axisU: SIMD3<Float>, axisV: SIMD3<Float>, axisW: SIMD3<Float>,
             half: SIMD3<Float>, color: SIMD4<Float>, twist: Float = 0) {
    // 轴对齐于 (axisU, axisV, axisW) 的长方体；twist：绕长轴旋转截面。
    // 45° 时菱形棱角对着相机——正视每根梁可见两个斜面（经典双色调）
    let (v2, w2) = twist == 0 ? (axisV, axisW) : (
        axisV * cos(twist) + axisW * sin(twist),
        axisW * cos(twist) - axisV * sin(twist)
    )
    let axes = [axisU, v2, w2]
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
            out.append(PenroseVertex(pos: SIMD4(p, 1), nrm: SIMD4(n, 0), color: color))
        }
    }
}

let inkBody = SIMD4<Float>(0.55, 0.56, 0.60, 1)   // 梁体基色：亮灰（明暗由光照与朝向分离）

// 三角形棱柱：2D 三角形 (a,b,c) 沿 z 挤出 [z0,z1]。用于角点斜接楔——
// 把两根梁都盖不到的斜接区补成干净的斜接尖角（外楔）与内角（内楔）
func trianglePrismInto(_ out: inout [PenroseVertex],
                       a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>,
                       z0: Float, z1: Float, color: SIMD4<Float>) {
    var p = [a, b, c]
    let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    if cross < 0 { p.reverse() }
    func vert(_ q: SIMD3<Float>, _ n: SIMD3<Float>) {
        out.append(PenroseVertex(pos: SIMD4(q.x, q.y, q.z, 1), nrm: SIMD4(n, 0), color: color))
    }
    let nz = SIMD3<Float>(0, 0, 1)
    for q in p { vert(SIMD3(q.x, q.y, z1), nz) }
    for q in p.reversed() { vert(SIMD3(q.x, q.y, z0), -nz) }
    for i in 0..<3 {
        let q0 = p[i], q1 = p[(i + 1) % 3]
        let e = q1 - q0
        let sideN = normalize(SIMD3<Float>(e.y, -e.x, 0))
        vert(SIMD3(q0.x, q0.y, z0), sideN); vert(SIMD3(q1.x, q1.y, z0), sideN); vert(SIMD3(q1.x, q1.y, z1), sideN)
        vert(SIMD3(q0.x, q0.y, z0), sideN); vert(SIMD3(q1.x, q1.y, z1), sideN); vert(SIMD3(q0.x, q0.y, z1), sideN)
    }
}

// V 片：120° 折梁平面片——占一个角 + 两条半边（各带搭接量），沿视线分层。
// 正面三色调（外半/内半/角部），底板给出厚度；魔法角度下三片拼成经典 tribar，
// 角点处进片端头搭在出片上（深度差使然），偏转后视差暴露三片分层
func vPieceInto(_ out: inout [PenroseVertex], corner cn: SIMD2<Float>,
                dirA: SIMD3<Float>, dirB: SIMD3<Float>,
                nrmA: SIMD3<Float>, nrmB: SIMD3<Float>,
                lenA: Float, lenB: Float, w: Float,
                zMid: Float, thick: Float, color: SIMD4<Float>) {
    let cn3 = SIMD3<Float>(cn.x, cn.y, 0)
    let bis = normalize(nrmA + nrmB)
    let mOut = cn3 + w * bis                   // 外斜接尖点（V 片外角）
    let mIn = cn3 - w * bis                    // 内斜接尖点（V 片内角）
    let offA = nrmA * (w / 2), offB = nrmB * (w / 2)
    let extA = dirA * lenA, extB = dirB * lenB
    let pA1 = cn3 + offA + extA    // 臂 A 末端外角
    let pA2 = cn3 - offA + extA    // 臂 A 末端内角
    let pB1 = cn3 + offB + extB    // 臂 B 末端外角
    let pB2 = cn3 - offB + extB    // 臂 B 末端内角
    let z0 = zMid - thick / 2, z1 = zMid + thick / 2
    // 底板：六边形 [pA1, mOut, pB1, pB2, mIn, pA2] 以角点为扇心拆 5 个三角棱柱
    let fan: [(SIMD3<Float>, SIMD3<Float>)] = [
        (pA1, mOut), (mOut, pB1), (pB1, pB2), (pB2, mIn), (mIn, pA2)
    ]
    for (a2d, b2d) in fan {
        trianglePrismInto(&out, a: SIMD3(a2d.x, a2d.y, 0), b: SIMD3(b2d.x, b2d.y, 0),
                          c: SIMD3(cn3.x, cn3.y, 0), z0: z0, z1: z1, color: color)
    }
    // 正面三色调：臂 A 外半暗/内半亮、臂 B 外半暗/内半亮——同片同向，
    // 三片旋转 120° 后明暗半区绕环轮转；片间跳变即角点织接的可见缝
    let plateZ = z1 + 0.0025
    let dark = SIMD4<Float>(0.13, 0.14, 0.17, 1)
    let light = SIMD4<Float>(0.44, 0.46, 0.52, 1)
    func plate(_ nrm: SIMD3<Float>, _ dir: SIMD3<Float>, _ len: Float, _ side: Float, _ col: SIMD4<Float>) {
        let c = SIMD3(cn3.x, cn3.y, plateZ) + nrm * side * (w / 4) + dir * (len / 2)
        boxInto(&out, center: c,
                axisU: dir, axisV: nrm, axisW: SIMD3<Float>(0, 0, 1),
                half: SIMD3(len / 2, w / 4, 0.0025), color: col)
    }
    plate(nrmA, dirA, lenA, 1, dark); plate(nrmA, dirA, lenA, -1, light)
    plate(nrmB, dirB, lenB, 1, dark); plate(nrmB, dirB, lenB, -1, light)
    // 角部补板：中暗，压住角区（读作角端面）
    let capC = SIMD3(cn3.x, cn3.y, plateZ) + bis * (w / 4)
    boxInto(&out, center: capC,
            axisU: bis, axisV: SIMD3<Float>(bis.y, -bis.x, 0), axisW: SIMD3<Float>(0, 0, 1),
            half: SIMD3(w / 2 + 0.01, w / 2, 0.0025), color: inkCap)
}

func makePenroseGeometry() -> [PenroseVertex] {
    var v: [PenroseVertex] = []
    let w = beamW, mu = depthSpan
    let side = triR * Float(sqrt(3.0))                  // 边长 √3·R
    let halfSide = side / 2
    let overlap: Float = 0.8                            // 边中点搭接长度的一半
    let lenArm = halfSide + overlap                     // V 片臂长：半边 + 搭接
    let thick: Float = 0.1
    let c = { (k: Int) -> SIMD2<Float> in
        let a = Float(90 + 120 * k) * Float.pi / 180
        return SIMD2<Float>(cos(a), sin(a)) * triR
    }
    for k in 0..<3 {
        let cn = c(k)
        let cnNext = c((k + 1) % 3)
        let cnPrev = c((k + 2) % 3)
        let dirA = normalize(SIMD3<Float>(cnNext.x - cn.x, cnNext.y - cn.y, 0))   // 臂 A：伸向下一条边
        let dirB = normalize(SIMD3<Float>(cnPrev.x - cn.x, cnPrev.y - cn.y, 0))   // 臂 B：伸向上一条边
        let nrmA = SIMD3<Float>(dirA.y, -dirA.x, 0)     // 边 A 外向（顺边方向取右侧）
        let nrmB = SIMD3<Float>(-dirB.y, dirB.x, 0)     // 臂 B 逆边方向：外向取左侧才是几何外侧
        let zMid = mu - Float(k) * mu                    // V0 最近，逐片远 μ
        vPieceInto(&v, corner: cn, dirA: dirA, dirB: dirB,
                   nrmA: nrmA, nrmB: nrmB, lenA: lenArm, lenB: lenArm, w: w,
                   zMid: zMid, thick: thick,
                   color: pieceTones[k])
    }
    return v
}

// ---- 投影：正交相机，带深度行（这次需要遮挡，z 行不再是零）----
func makeMVP(yaw: Float, pitch: Float, aspect: Float, halfH: Float) -> simd_float4x4 {
    let dist: Float = 14.0
    let dir = SIMD3<Float>(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    let fw = normalize(-dir)
    let rt = normalize(cross(fw, SIMD3<Float>(0, 1, 0)))
    let up = cross(rt, fw)
    let halfW = halfH * aspect
    let zNear: Float = 2.0, zFar: Float = 29.0   // 自由旋转后视深范围 ≈ [3.7, 24.3]，zNear 留足余量
    let q = 1 / (zFar - zNear)
    // clip = M·p：xy 正交缩小，z 行把视深线性压进 [0,1]（Metal 深度范围）
    return simd_float4x4(columns: (
        SIMD4<Float>(rt.x / halfW, up.x / halfH, -dir.x * q, 0),
        SIMD4<Float>(rt.y / halfW, up.y / halfH, -dir.y * q, 0),
        SIMD4<Float>(rt.z / halfW, up.z / halfH, -dir.z * q, 0),
        SIMD4<Float>(0, 0, (dist - zNear) * q, 1)
    ))
}

// ---- 着色器：面平坦 Lambert（法线在几何阶段逐面给出），墨色纸面风 ----
let penroseShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct PenroseUniforms {
    float4x4 mvp;
    float4 light;      // xyz = 光照方向
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
    constant PenroseUniforms &u [[buffer(1)]],
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
    constant PenroseUniforms &u [[buffer(1)]]
) {
    float diff = clamp(dot(normalize(in.nrm), u.light.xyz), 0.0, 1.0);
    return float4(in.color * (0.32 + 0.68 * diff), 1.0);   // 基色 ×（环境 + 漫反射）
}
"""

func makePenrosePipeline(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let library = try! device.makeLibrary(source: penroseShaderSource, options: nil)
    guard let vf = library.makeFunction(name: "vertex_main"),
          let ff = library.makeFunction(name: "fragment_main") else {
        fatalError("着色器函数缺失：vertex_main / fragment_main")
    }
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vf
    desc.fragmentFunction = ff
    desc.colorAttachments[0].pixelFormat = colorFormat
    // 这次是真正的 3D 遮挡：需要深度测试
    desc.depthAttachmentPixelFormat = depthFormat
    return try! device.makeRenderPipelineState(descriptor: desc)
}

let modeDesc = ["深度跨度 μ=3.15（断裂角 ≈ 7°）", "深度跨度 μ=1.5（断裂角 ≈ 15°）", "深度跨度 μ=0.4（断裂角 ≈ 49°，几乎拖不断）"]

// MARK: - 窗口模式（自由旋转 + 滚轮缩放 + F 循环缺口 + 重置按钮 + 标题栏 FPS）

class PenroseViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var vertexCount = 0
    var yaw: Float = 0
    var pitch: Float = 0
    var halfH: Float = 3.7        // 正交视野半高（世界单位），滚轮缩放可调
    var gapIndex = 0
    let pitchLimit: Float = 89.0 * Float.pi / 180   // 自由旋转的俯仰上限（避免视向上矢量退化）
    var frameCount = 0
    var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = PenroseView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        metalView.clearColor = MTLClearColor(red: Double(paper.r), green: Double(paper.g), blue: Double(paper.b), alpha: 1)
        metalView.depthStencilPixelFormat = .depth16Unorm
        view = metalView
        let resetButton = NSButton(title: "重置", target: self, action: #selector(resetState))
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.toolTip = "回到魔法角度（正视图）并恢复深度跨度 μ=1.2"
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        metalView.addSubview(resetButton)
        NSLayoutConstraint.activate([
            resetButton.trailingAnchor.constraint(equalTo: metalView.trailingAnchor, constant: -12),
            resetButton.topAnchor.constraint(equalTo: metalView.topAnchor, constant: 12),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? PenroseView)?.controller = self
        queue = device.makeCommandQueue()
        pipelineState = makePenrosePipeline(device: device,
                                            colorFormat: metalView.colorPixelFormat,
                                            depthFormat: metalView.depthStencilPixelFormat)
        rebuildGeometry()
        print("Device: \(device.name)")
        print("场景：三片 V 形折梁沿边搭接（每片一角两半边），层间深度差 μ=\(depthSpan)")
        print("[Pipeline ready] 正交魔法角度 · 深度测试遮挡 · 断裂角 ≈ 19°（w/2μ）")
        print("拖拽：自由旋转（偏出 ±19° 即断口，滚轮缩放） · F：循环深度跨度 μ · 「重置」回魔法角度")
    }

    func rebuildGeometry() {
        let geo = makePenroseGeometry()
        vertexCount = geo.count
        vertexBuffer = device.makeBuffer(
            bytes: geo,
            length: geo.count * MemoryLayout<PenroseVertex>.stride,
            options: .storageModeShared
        )
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    // 重置 = 回到魔法角度 + 默认缩放 + 最大深度差
    @objc func resetState() {
        yaw = 0
        pitch = 0
        halfH = 3.7
        gapIndex = 0
        depthSpan = spanLevels[0]
        rebuildGeometry()
        print(modeDesc[0] + " · 已重置")
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
        let light = normalize(SIMD4<Float>(0.15, 0.9, 0.42, 0))
        var u = PenroseUniforms(
            mvp: makeMVP(yaw: yaw, pitch: pitch, aspect: Float(size.width / size.height), halfH: halfH),
            light: light
        )
        enc.setVertexBytes(&u, length: MemoryLayout<PenroseUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<PenroseUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsWindowStart
        if elapsed >= 2.0 {
            let fps = Double(frameCount) / elapsed
            let off = max(abs(yaw), abs(pitch)) * 180 / Float.pi
            let state = off < 19 ? "✓ 错觉成立" : "✗ 已穿帮"
            view.window?.title = "Penrose 三角 · \(state) · 深度 μ=\(depthSpan) · FPS \(Int(fps)) · 自由旋转 滚轮缩放"
            print(String(format: "FPS ≈ %.1f（标题栏同步显示）", fps))
            frameCount = 0
            fpsWindowStart = now
        }
    }
}

class PenroseView: MTKView {
    weak var controller: PenroseViewController?
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
        // 自由旋转：错觉只在魔法角度 ±3° 内成立，转开即断（标题栏实时提示）
        c.yaw += dYaw
        c.pitch = min(c.pitchLimit, max(-c.pitchLimit, c.pitch + dPitch))
        lastMouse = now
    }

    override func scrollWheel(with event: NSEvent) {
        guard let c = controller else { return }
        let f = exp(Float(event.scrollingDeltaY) * 0.01)
        c.halfH = min(13.0, max(1.8, c.halfH * f))
    }

    override func magnify(with event: NSEvent) {
        guard let c = controller else { return }
        c.halfH = min(13.0, max(1.8, c.halfH / Float(event.magnification)))
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller, event.charactersIgnoringModifiers == "f" else {
            super.keyDown(with: event)
            return
        }
        c.gapIndex = (c.gapIndex + 1) % spanLevels.count
        depthSpan = spanLevels[c.gapIndex]
        c.rebuildGeometry()
        print(modeDesc[c.gapIndex])
    }
}

class PenroseAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: PenroseViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Penrose 三角 · 自由旋转 · 滚轮缩放 · F 换缺口 · 重置"
        window.center()
        controller = PenroseViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 离屏导出（closed = 魔法角度闭合；open = 偏转 8° 露出断口）

func exportPenrosePNG(path: String, open: Bool, width: Int = 1920, height: Int = 1080) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let pipeline = makePenrosePipeline(device: device, colorFormat: .rgba8Unorm, depthFormat: .depth16Unorm)
    let geo = makePenroseGeometry()
    let vertexBuffer = device.makeBuffer(
        bytes: geo,
        length: geo.count * MemoryLayout<PenroseVertex>.stride,
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
    let yaw: Float = open ? 8.0 * Float.pi / 180 : 0
    let pitch: Float = open ? 4.0 * Float.pi / 180 : 0
    var u = PenroseUniforms(
        mvp: makeMVP(yaw: yaw, pitch: pitch, aspect: Float(width) / Float(height), halfH: 3.7),
        light: normalize(SIMD4<Float>(0.0, 1.0, 0.35, 0))
    )
    enc.setVertexBytes(&u, length: MemoryLayout<PenroseUniforms>.stride, index: 1)
    enc.setFragmentBytes(&u, length: MemoryLayout<PenroseUniforms>.stride, index: 1)
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
    print(open ? "断口视角（偏转 45°）· 三片 V 形折梁  尺寸 \(width)×\(height)"
               : "闭合视角（魔法角度正交）· 经典 tribar  尺寸 \(width)×\(height)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runPenrose() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        let open = args.count > i + 2 && args[i + 2].lowercased() == "open"
        exportPenrosePNG(path: args[i + 1], open: open)
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = PenroseAppDelegate()
    app.delegate = delegate
    app.run()
}
