import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// ---- 模拟参数 ----

let fluidSimRes = 256
let fluidJacobiIters = 30
let fluidDyeDissipation: Float = 0.999
let fluidVelDissipation: Float = 0.99

// 内核公共参数。SIMD4 打包避免 Swift/MSL 对齐差异：
// u0 = (dt, dissipation, 0, 0)
struct FluidAdvParams {
    var u0: SIMD4<Float>
}

// splat 参数：u0 = (px, py, radius, 0)，value = 注入量（速度矢量或染料颜色）
struct FluidSplatParams {
    var u0: SIMD4<Float>
    var value: SIMD4<Float>
}

// ---- compute 内核（全部源码内嵌，运行时编译）----

let fluidKernelSource = """
#include <metal_stdlib>
using namespace metal;

struct FluidAdvParams {
    float4 u0;   // dt, dissipation, 0, 0
};

struct FluidSplatParams {
    float4 u0;    // px, py, radius, 0
    float4 value; // 注入量
};

float2 clampPos(uint2 p, uint2 size) {
    int2 c = clamp(int2(p), int2(0), int2(size) - 1);
    return float2(c);
}

// 手写双线性采样：pos 为网格坐标（可为小数），clamp 到边界
float4 bilerp(texture2d<float, access::read> tex, float2 pos, uint2 size) {
    float2 p = clamp(pos, float2(0.5, 0.5), float2(size) - float2(0.5, 0.5));
    float2 f = fract(p - 0.5);
    uint2 i = uint2(p - f);
    uint2 i1 = uint2(min(i.x + 1, size.x - 1), min(i.y + 1, size.y - 1));
    float4 a = tex.read(i);
    float4 b = tex.read(uint2(i1.x, i.y));
    float4 c = tex.read(uint2(i.x, i1.y));
    float4 d = tex.read(i1);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// 半拉格朗日平流：沿速度场回溯 dt 秒，取出发点的值
kernel void advect(
    texture2d<float, access::read>  field  [[texture(0)]],
    texture2d<float, access::read>  velTex [[texture(1)]],
    texture2d<float, access::write> outTex [[texture(2)]],
    constant FluidAdvParams &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    uint2 size = uint2(outTex.get_width(), outTex.get_height());
    float dt = p.u0.x;
    float diss = p.u0.y;
    float2 vel = velTex.read(gid).xy;
    float2 back = float2(gid) - vel * dt;
    float4 v = bilerp(field, back, size) * diss;
    outTex.write(clamp(v, -10.0, 10.0), gid);
}

// 力/染料注入：以 (px,py) 为中心的高斯斑点
kernel void splat(
    texture2d<float, access::read>  inTex  [[texture(0)]],
    texture2d<float, access::write> outTex [[texture(1)]],
    constant FluidSplatParams &sp [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) { return; }
    float2 d = float2(gid) - sp.u0.xy;
    float4 base = inTex.read(gid);
    base += sp.value * exp(-dot(d, d) / sp.u0.z);
    outTex.write(clamp(base, -10.0, 10.0), gid);
}

float2 clampedNb(uint2 p, uint2 size) {
    return clampPos(p, size);
}

// 散度：∇·v（中心差分，边界用 clamp）
kernel void divergence(
    texture2d<float, access::read>  vel  [[texture(0)]],
    texture2d<float, access::write> div  [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= div.get_width() || gid.y >= div.get_height()) { return; }
    uint2 size = uint2(div.get_width(), div.get_height());
    float2 L = vel.read(uint2(clampedNb(uint2(gid.x, gid.y) - uint2(1, 0), size))).xy;
    float2 R = vel.read(uint2(clampedNb(uint2(gid.x, gid.y) + uint2(1, 0), size))).xy;
    float2 D = vel.read(uint2(clampedNb(uint2(gid.x, gid.y) - uint2(0, 1), size))).xy;
    float2 U = vel.read(uint2(clampedNb(uint2(gid.x, gid.y) + uint2(0, 1), size))).xy;
    float d = 0.5 * (R.x - L.x + U.y - D.y);
    div.write(float4(d, 0.0, 0.0, 1.0), gid);
}

// 压力泊松方程的 Jacobi 迭代：p = (四邻和 - 散度) / 4
kernel void jacobi(
    texture2d<float, access::read>  pressIn  [[texture(0)]],
    texture2d<float, access::read>  div      [[texture(1)]],
    texture2d<float, access::write> pressOut [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= pressOut.get_width() || gid.y >= pressOut.get_height()) { return; }
    uint2 size = uint2(pressOut.get_width(), pressOut.get_height());
    float d = div.read(gid).x;
    float l = pressIn.read(uint2(clampedNb(uint2(gid.x, gid.y) - uint2(1, 0), size))).x;
    float r = pressIn.read(uint2(clampedNb(uint2(gid.x, gid.y) + uint2(1, 0), size))).x;
    float u = pressIn.read(uint2(clampedNb(uint2(gid.x, gid.y) + uint2(0, 1), size))).x;
    float dn = pressIn.read(uint2(clampedNb(uint2(gid.x, gid.y) - uint2(0, 1), size))).x;
    float p = (l + r + u + dn - d) * 0.25;
    pressOut.write(float4(p, 0.0, 0.0, 1.0), gid);
}

// 减去压力梯度：速度变为无散（不可压缩）
kernel void gradientSubtract(
    texture2d<float, access::read>  press  [[texture(0)]],
    texture2d<float, access::read>  velIn  [[texture(1)]],
    texture2d<float, access::write> velOut [[texture(2)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= velOut.get_width() || gid.y >= velOut.get_height()) { return; }
    uint2 size = uint2(velOut.get_width(), velOut.get_height());
    float l = press.read(uint2(clampedNb(uint2(gid.x, gid.y) - uint2(1, 0), size))).x;
    float r = press.read(uint2(clampedNb(uint2(gid.x, gid.y) + uint2(1, 0), size))).x;
    float u = press.read(uint2(clampedNb(uint2(gid.x, gid.y) + uint2(0, 1), size))).x;
    float dn = press.read(uint2(clampedNb(uint2(gid.x, gid.y) - uint2(0, 1), size))).x;
    float2 v = velIn.read(gid).xy;
    v -= float2(r - l, u - dn) * 0.5;
    velOut.write(float4(v, 0.0, 1.0), gid);
}
"""

// ---- 渲染着色器：全屏采样染料场 ----

let fluidRenderSource = """
#include <metal_stdlib>
using namespace metal;

struct FluidRenderOut {
    float4 position [[position]];
    float2 uv;
};

vertex FluidRenderOut vertex_main(
    const device float2 *positions [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    FluidRenderOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = positions[vid].xy * 0.5 + 0.5;
    return out;
}

fragment float4 fragment_main(FluidRenderOut in [[stage_in]], texture2d<float> dye [[texture(0)]]) {
    constexpr sampler samp(address::clamp_to_edge, filter::linear);
    float3 c = dye.sample(samp, in.uv).rgb;
    return float4(pow(clamp(c * 1.6, 0.0, 1.0), float3(0.9)), 1.0);   // 提亮 + 轻微 gamma
}
"""

let fluidQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

// ---- Swift 侧管线与纹理管理 ----

func makeFluidLibrary(device: MTLDevice) -> MTLLibrary {
    try! device.makeLibrary(source: fluidKernelSource, options: nil)
}

func makeFluidPS(device: MTLDevice, name: String) -> MTLComputePipelineState {
    let lib = makeFluidLibrary(device: device)
    return try! device.makeComputePipelineState(function: lib.makeFunction(name: name)!)
}

func makeFluidRenderPS(device: MTLDevice, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let lib = try! device.makeLibrary(source: fluidRenderSource, options: nil)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = lib.makeFunction(name: "vertex_main")
    desc.fragmentFunction = lib.makeFunction(name: "fragment_main")
    desc.colorAttachments[0].pixelFormat = colorFormat
    return try! device.makeRenderPipelineState(descriptor: desc)
}

func makeFluidTex(device: MTLDevice) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: fluidSimRes, height: fluidSimRes, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    return device.makeTexture(descriptor: d)!
}

func fluidDispatch(enc: MTLComputeCommandEncoder, ps: MTLComputePipelineState) {
    let w = ps.threadExecutionWidth
    let h = ps.maxTotalThreadsPerThreadgroup / w
    enc.dispatchThreadgroups(MTLSize(width: (fluidSimRes + w - 1) / w, height: (fluidSimRes + h - 1) / h, depth: 1),
                             threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
}

// 一次完整模拟步（不含 splat）：平流速度 → 散度 → Jacobi ×N → 减梯度 → 平流染料
struct FluidFields {
    var vel: [MTLTexture]      // [0]/[1] 乒乓
    var dye: [MTLTexture]
    var press: [MTLTexture]
    var div: MTLTexture
    var velCur = 0
    var dyeCur = 0
    var pressCur = 0

    init(device: MTLDevice) {
        vel = [makeFluidTex(device: device), makeFluidTex(device: device)]
        dye = [makeFluidTex(device: device), makeFluidTex(device: device)]
        press = [makeFluidTex(device: device), makeFluidTex(device: device)]
        div = makeFluidTex(device: device)
    }
}

func fluidStep(cb: MTLCommandBuffer, advPS: MTLComputePipelineState, divPS: MTLComputePipelineState,
               jacPS: MTLComputePipelineState, gradPS: MTLComputePipelineState, fields: inout FluidFields) {
    var adv = FluidAdvParams(u0: SIMD4(1.0 / 60.0, fluidVelDissipation, 0, 0))
    let enc = cb.makeComputeCommandEncoder()!

    // 1) 平流速度
    enc.setComputePipelineState(advPS)
    enc.setTexture(fields.vel[fields.velCur], index: 0)
    enc.setTexture(fields.vel[fields.velCur], index: 1)
    enc.setTexture(fields.vel[1 - fields.velCur], index: 2)
    enc.setBytes(&adv, length: MemoryLayout<FluidAdvParams>.stride, index: 0)
    fluidDispatch(enc: enc, ps: advPS)
    fields.velCur = 1 - fields.velCur

    // 2) 散度
    enc.setComputePipelineState(divPS)
    enc.setTexture(fields.vel[fields.velCur], index: 0)
    enc.setTexture(fields.div, index: 1)
    fluidDispatch(enc: enc, ps: divPS)

    // 3) 压力 Jacobi 迭代
    enc.setComputePipelineState(jacPS)
    for i in 0..<fluidJacobiIters {
        enc.setTexture(fields.press[fields.pressCur], index: 0)
        enc.setTexture(fields.div, index: 1)
        enc.setTexture(fields.press[1 - fields.pressCur], index: 2)
        fluidDispatch(enc: enc, ps: jacPS)
        fields.pressCur = 1 - fields.pressCur
    }

    // 4) 减压力梯度
    enc.setComputePipelineState(gradPS)
    enc.setTexture(fields.press[fields.pressCur], index: 0)
    enc.setTexture(fields.vel[fields.velCur], index: 1)
    enc.setTexture(fields.vel[1 - fields.velCur], index: 2)
    fluidDispatch(enc: enc, ps: gradPS)
    fields.velCur = 1 - fields.velCur

    // 5) 平流染料
    adv = FluidAdvParams(u0: SIMD4(1.0 / 60.0, fluidDyeDissipation, 0, 0))
    enc.setComputePipelineState(advPS)
    enc.setTexture(fields.dye[fields.dyeCur], index: 0)
    enc.setTexture(fields.vel[fields.velCur], index: 1)
    enc.setTexture(fields.dye[1 - fields.dyeCur], index: 2)
    enc.setBytes(&adv, length: MemoryLayout<FluidAdvParams>.stride, index: 0)
    fluidDispatch(enc: enc, ps: advPS)
    fields.dyeCur = 1 - fields.dyeCur

    enc.endEncoding()
}

func fluidSplat(cb: MTLCommandBuffer, splatPS: MTLComputePipelineState, fields: inout FluidFields,
                px: Float, py: Float, radius: Float, vel: SIMD2<Float>, dye: SIMD4<Float>) {
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(splatPS)
    // 速度注入
    enc.setTexture(fields.vel[fields.velCur], index: 0)
    enc.setTexture(fields.vel[1 - fields.velCur], index: 1)
    var spVel = FluidSplatParams(u0: SIMD4(px, py, radius, 0), value: SIMD4(vel.x, vel.y, 0, 0))
    enc.setBytes(&spVel, length: MemoryLayout<FluidSplatParams>.stride, index: 0)
    fluidDispatch(enc: enc, ps: splatPS)
    fields.velCur = 1 - fields.velCur
    // 染料注入
    enc.setTexture(fields.dye[fields.dyeCur], index: 0)
    enc.setTexture(fields.dye[1 - fields.dyeCur], index: 1)
    var spDye = FluidSplatParams(u0: SIMD4(px, py, radius * 0.6, 0), value: SIMD4(dye.x, dye.y, dye.z, 1))
    enc.setBytes(&spDye, length: MemoryLayout<FluidSplatParams>.stride, index: 0)
    fluidDispatch(enc: enc, ps: splatPS)
    fields.dyeCur = 1 - fields.dyeCur
    enc.endEncoding()
}

func fluidRenderFrame(encoder: MTLRenderCommandEncoder, renderPS: MTLRenderPipelineState,
                      quadBuffer: MTLBuffer, fields: FluidFields, dyeIndex: Int) {
    encoder.setRenderPipelineState(renderPS)
    encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
    encoder.setFragmentTexture(fields.dye[dyeIndex], index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fluidQuad.count)
}

// MARK: - 窗口模式

class FluidViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var hue: Float = 0.15
    var pendingSplat: (px: Float, py: Float, fx: Float, fy: Float, color: SIMD4<Float>)? = nil
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var advPS: MTLComputePipelineState!
    var splatPS: MTLComputePipelineState!
    var divPS: MTLComputePipelineState!
    var jacPS: MTLComputePipelineState!
    var gradPS: MTLComputePipelineState!
    var renderPS: MTLRenderPipelineState!
    var quadBuffer: MTLBuffer!
    var fields: FluidFields!

    var lastTime: Double = 0
    var frameCount = 0
    var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = FluidView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? FluidView)?.controller = self
        queue = device.makeCommandQueue()
        advPS = makeFluidPS(device: device, name: "advect")
        splatPS = makeFluidPS(device: device, name: "splat")
        divPS = makeFluidPS(device: device, name: "divergence")
        jacPS = makeFluidPS(device: device, name: "jacobi")
        gradPS = makeFluidPS(device: device, name: "gradientSubtract")
        renderPS = makeFluidRenderPS(device: device, colorFormat: metalView.colorPixelFormat)
        quadBuffer = device.makeBuffer(bytes: fluidQuad, length: fluidQuad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        fields = FluidFields(device: device)
        print("Device: \(device.name)")
        print("流体：\(fluidSimRes)² 模拟 · Jacobi \(fluidJacobiIters) 轮 · 拖动鼠标搅动染料")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let cb = queue.makeCommandBuffer() else { return }
        if let s = pendingSplat {
            fluidSplat(cb: cb, splatPS: splatPS, fields: &fields,
                       px: s.px, py: s.py, radius: 24,
                       vel: SIMD2(s.fx * 12, s.fy * 12), dye: s.color)
            pendingSplat = nil
        }
        fluidStep(cb: cb, advPS: advPS, divPS: divPS, jacPS: jacPS, gradPS: gradPS, fields: &fields)

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }
        let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
        fluidRenderFrame(encoder: enc, renderPS: renderPS, quadBuffer: quadBuffer!, fields: fields, dyeIndex: fields.dyeCur)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        frameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsWindowStart
        if elapsed >= 2.0 {
            let fps = Double(frameCount) / elapsed
            view.window?.title = String(format: "2D 流体 · FPS %.0f · 拖动鼠标搅动", fps)
            frameCount = 0
            fpsWindowStart = now
        }
    }
}

class FluidView: MTKView {
    weak var controller: FluidViewController?
    var mouseIsDown = false
    var lastPos = NSPoint.zero

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseIsDown = true
        lastPos = convert(event.locationInWindow, from: nil)
        queueSplat(at: lastPos, prev: lastPos)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mouseIsDown else { return }
        let now = convert(event.locationInWindow, from: nil)
        queueSplat(at: now, prev: lastPos)
        lastPos = now
    }

    override func mouseUp(with event: NSEvent) {
        mouseIsDown = false
    }

    // 窗口坐标（y 向下，逻辑 800×600）→ 模拟网格坐标（y 向上，256×256）
    func queueSplat(at pos: NSPoint, prev: NSPoint) {
        guard let c = controller else { return }
        let px = Float(pos.x / bounds.width) * Float(fluidSimRes)
        let py = Float(1 - pos.y / bounds.height) * Float(fluidSimRes)
        let ppx = Float(prev.x / bounds.width) * Float(fluidSimRes)
        let ppy = Float(1 - prev.y / bounds.height) * Float(fluidSimRes)
        c.hue = (c.hue + 0.21).truncatingRemainder(dividingBy: 1)
        c.pendingSplat = (px, py, px - ppx, py - ppy,
                          SIMD4(0.2 + c.hue * 0.8, 0.3 + (1 - c.hue) * 0.6, 0.4 + c.hue * 0.4, 1))
    }
}

class FluidAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: FluidViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "2D 流体 Stable Fluids · 拖动鼠标搅动染料"
        window.center()
        controller = FluidViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - test（5 秒涡旋对流验收）与 bench / export

// 验收：固定 seed 注入染料与双涡旋驱动，跑 300 帧（5 秒）后染料仍有结构
func fluidTest(device: MTLDevice, queue: MTLCommandQueue) {
    let advPS = makeFluidPS(device: device, name: "advect")
    let splatPS = makeFluidPS(device: device, name: "splat")
    let divPS = makeFluidPS(device: device, name: "divergence")
    let jacPS = makeFluidPS(device: device, name: "jacobi")
    let gradPS = makeFluidPS(device: device, name: "gradientSubtract")
    var fields = FluidFields(device: device)

    let cb0 = queue.makeCommandBuffer()!
    // 初始染料：中央一坨
    fluidSplat(cb: cb0, splatPS: splatPS, fields: &fields, px: 128, py: 128, radius: 32, vel: SIMD2(0, 0), dye: SIMD4(0.5, 1.0, 0.8, 1))
    cb0.commit()
    cb0.waitUntilCompleted()

    for f in 0..<300 {
        let cb = queue.makeCommandBuffer()!
        // 双射流驱动涡旋：左右两侧交替注入反向速度（纯速度注入，不加染料）
        let dir: Float = (f / 30) % 2 == 0 ? 1 : -1
        fluidSplat(cb: cb, splatPS: splatPS, fields: &fields, px: 60, py: 128, radius: 12,
                   vel: SIMD2(150 * dir, -90 * dir), dye: SIMD4(0.15, 0.18, 0.25, 0))
        fluidSplat(cb: cb, splatPS: splatPS, fields: &fields, px: 196, py: 128, radius: 12,
                   vel: SIMD2(-150 * dir, 90 * dir), dye: SIMD4(0.15, 0.18, 0.25, 0))
        fluidStep(cb: cb, advPS: advPS, divPS: divPS, jacPS: jacPS, gradPS: gradPS, fields: &fields)
        cb.commit()
        cb.waitUntilCompleted()
    }

    // 回读染料场统计（rgba16Float 是 16 位半精度浮点，必须解码而非按 Float32 读）
    var halves = [UInt16](repeating: 0, count: fluidSimRes * fluidSimRes * 4)
    fields.dye[fields.dyeCur].getBytes(&halves, bytesPerRow: fluidSimRes * 8, from: MTLRegionMake2D(0, 0, fluidSimRes, fluidSimRes), mipmapLevel: 0)
    func halfToFloat(_ h: UInt16) -> Float {
        let sign: Float = (h >> 15) & 1 == 1 ? -1 : 1
        let e = Int((h >> 10) & 0x1F)
        let frac = Float(h & 0x3FF)
        if e == 0 { return sign * frac * pow(2, -24) }
        if e == 31 { return frac == 0 ? sign * Float.infinity : Float.nan }
        return sign * pow(2, Float(e - 15)) * (1 + frac / 1024)
    }
    var active = 0, nan = false
    var maxV: Float = 0
    for i in 0..<fluidSimRes * fluidSimRes {
        let v = halfToFloat(halves[i * 4])
        if v.isNaN { nan = true }
        if v > 0.05 { active += 1 }
        maxV = max(maxV, v)
    }
    let frac = Float(active) / Float(fluidSimRes * fluidSimRes) * 100
    print("300 帧（5 秒）后：活性染料像素(>0.05) \(frac.rounded())% · 峰值 \(String(format: "%.2f", maxV)) · NaN \(nan ? "有" : "无")")
    let ok = !nan && frac >= 8 && maxV >= 0.3
    print(ok ? "✅ 通过：染料有结构地持续 5 秒，未消散成糊" : "❌ 未通过")
    exit(ok ? 0 : 1)
}

func fluidBench(device: MTLDevice, queue: MTLCommandQueue) {
    let advPS = makeFluidPS(device: device, name: "advect")
    let splatPS = makeFluidPS(device: device, name: "splat")
    let divPS = makeFluidPS(device: device, name: "divergence")
    let jacPS = makeFluidPS(device: device, name: "jacobi")
    let gradPS = makeFluidPS(device: device, name: "gradientSubtract")
    var fields = FluidFields(device: device)
    let renderPS = makeFluidRenderPS(device: device, colorFormat: .rgba8Unorm)

    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<100 {
        let cb = queue.makeCommandBuffer()!
        fluidStep(cb: cb, advPS: advPS, divPS: divPS, jacPS: jacPS, gradPS: gradPS, fields: &fields)
        let enc = cb.makeRenderCommandEncoder(descriptor: blankRPD(device: device))!
        fluidRenderFrame(encoder: enc, renderPS: renderPS, quadBuffer: quadBufferShared(device: device), fields: fields, dyeIndex: fields.dyeCur)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 100
    print(String(format: "完整管线（含 30 轮 Jacobi 与渲染）单帧 %.2f ms（预算 16.6 ms）", ms))
    print(ms < 16.6 ? "✅ 60 FPS 预算：通过" : "❌ 未达预算")
}

func blankRPD(device: MTLDevice) -> MTLRenderPassDescriptor {
    let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 800, height: 600, mipmapped: false)
    td.usage = [.renderTarget]
    let tex = device.makeTexture(descriptor: td)!
    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = tex
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    return rpd
}

var fluidQuadBufferCache: MTLBuffer?
func quadBufferShared(device: MTLDevice) -> MTLBuffer {
    if fluidQuadBufferCache == nil {
        fluidQuadBufferCache = device.makeBuffer(bytes: fluidQuad, length: fluidQuad.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
    }
    return fluidQuadBufferCache!
}

func exportFluidPNG(path: String, width: Int = 800, height: Int = 600) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let advPS = makeFluidPS(device: device, name: "advect")
    let splatPS = makeFluidPS(device: device, name: "splat")
    let divPS = makeFluidPS(device: device, name: "divergence")
    let jacPS = makeFluidPS(device: device, name: "jacobi")
    let gradPS = makeFluidPS(device: device, name: "gradientSubtract")
    let renderPS = makeFluidRenderPS(device: device, colorFormat: .rgba8Unorm)
    var fields = FluidFields(device: device)

    let cb0 = queue.makeCommandBuffer()!
    fluidSplat(cb: cb0, splatPS: splatPS, fields: &fields, px: 128, py: 128, radius: 32, vel: SIMD2(0, 0), dye: SIMD4(0.5, 1.0, 0.8, 1))
    cb0.commit()
    cb0.waitUntilCompleted()

    let totalFrames = ProcessInfo.processInfo.environment["FRAMES"].flatMap(Int.init) ?? 120
    for f in 0..<totalFrames {
        let cb = queue.makeCommandBuffer()!
        let dir: Float = (f / 30) % 2 == 0 ? 1 : -1
        fluidSplat(cb: cb, splatPS: splatPS, fields: &fields, px: 60, py: 128, radius: 12,
                   vel: SIMD2(150 * dir, -90 * dir), dye: SIMD4(0.15, 0.18, 0.25, 0))
        fluidSplat(cb: cb, splatPS: splatPS, fields: &fields, px: 196, py: 128, radius: 12,
                   vel: SIMD2(-150 * dir, 90 * dir), dye: SIMD4(0.15, 0.18, 0.25, 0))
        fluidStep(cb: cb, advPS: advPS, divPS: divPS, jacPS: jacPS, gradPS: gradPS, fields: &fields)
        cb.commit()
        cb.waitUntilCompleted()
    }

    let verts = fluidQuad
    let quadBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
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
    fluidRenderFrame(encoder: enc, renderPS: renderPS, quadBuffer: quadBuffer!, fields: fields, dyeIndex: fields.dyeCur)
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
    print("双射流驱动 \(totalFrames) 帧后的染料场  尺寸 \(width)×\(height)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

func runFluid() {
    let args = CommandLine.arguments
    if args.contains("test") {
        if let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() {
            print("Device: \(device.name)")
            fluidTest(device: device, queue: queue)
        }
        exit(1)
    }
    if args.contains("bench") {
        if let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() {
            print("Device: \(device.name)")
            fluidBench(device: device, queue: queue)
        }
        exit(0)
    }
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        exportFluidPNG(path: args[i + 1])
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = FluidAppDelegate()
    app.delegate = delegate
    app.run()
}
