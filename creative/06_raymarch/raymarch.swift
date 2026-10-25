import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// 相机参数。SIMD4 打包避免 Swift/MSL 对齐差异：
// u0 = (yaw, pitch, dist, time)
// u1 = (resX, resY, 0, 0)
struct RaymarchUniforms {
    var u0: SIMD4<Float>
    var u1: SIMD4<Float>
}

// 片元着色器：SDF 场 + 球体追踪 + 软阴影 + AO + 雾
let raymarchShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct RaymarchUniforms {
    float4 u0;   // yaw, pitch, dist, time
    float4 u1;   // resX, resY, 0, 0
};

// ---- SDF 基元：每个函数返回"所在点到该表面最近距离"----

float sdSphere(float3 p, float r) {
    return length(p) - r;
}

float sdBox(float3 p, float3 b) {
    float3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float sdCapsule(float3 p, float3 a, float3 b, float r) {
    float3 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// 光滑并集：k 控制融合半径，两形状靠近时缝上"长"出平滑过渡
float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

// 场 = 地面(平面 y=0) + 球 + 胶囊与盒子的光滑并集
float mapScene(float3 p) {
    float ground = p.y;                                  // 地面：到 y=0 平面的距离
    float sphere = sdSphere(p - float3(-0.9, 0.55, 0.0), 0.55);
    float capsule = sdCapsule(p, float3(0.95, 0.45, 0.0), float3(0.95, 1.08, 0.0), 0.30);
    float box = sdBox(p - float3(0.95, 0.36, 0.0), float3(0.34, 0.36, 0.34));
    float blob = smin(capsule, box, 0.25);               // 盒子坐地 + 胶囊立顶 → 软塔造型
    return min(ground, min(sphere, blob));
}

// 数值梯度求法线：沿 xyz 各正负方向采 6 次（中心差分），归一化即表面法线
float3 calcNormal(float3 p) {
    float e = 0.0015;
    float2 h = float2(e, 0.0);
    return normalize(float3(
        mapScene(p + h.xyy) - mapScene(p - h.xyy),
        mapScene(p + h.yxy) - mapScene(p - h.yxy),
        mapScene(p + h.yyx) - mapScene(p - h.yyx)));
}

// 软阴影：从命中点向光源步进，记录"离遮挡物最近距离与已行距离之比"的最小值
// k 越大阴影越硬；比率小 → 半影宽
float softShadow(float3 ro, float3 rd) {
    float res = 1.0;
    float t = 0.02;
    for (int i = 0; i < 32; i++) {
        float h = mapScene(ro + rd * t);
        res = min(res, 8.0 * h / t);
        t += clamp(h, 0.02, 0.25);
        if (res < 0.005 || t > 12.0) { break; }
    }
    return clamp(res, 0.0, 1.0);
}

// 环境光遮蔽：沿法线采 4 个高度，场值比理论自由空间低多少 → 遮蔽程度
float calcAO(float3 p, float3 n) {
    float occ = 0.0, sca = 1.0;
    for (int i = 0; i < 4; i++) {
        float h = 0.01 + 0.12 * float(i);
        occ += (h - mapScene(p + n * h)) * sca;
        sca *= 0.7;
    }
    return clamp(1.0 - 2.0 * occ, 0.0, 1.0);
}

fragment float4 fragment_main(
    float4 fragCoord [[position]],
    constant RaymarchUniforms &u [[buffer(1)]]
) {
    float2 res = u.u1.xy;
    float yaw = u.u0.x, pitch = u.u0.y, dist = u.u0.z;

    // 像素 → 相机射线（轨道相机绕目标点转）
    // Metal 像素坐标 y 向下，世界坐标 y 向上——必须翻转，否则整幅画面上下颠倒
    float2 uv = (float2(fragCoord.x, res.y - fragCoord.y) - 0.5 * res) / res.y;
    float3 target = float3(0.0, 0.45, 0.0);
    float3 ro = target + dist * float3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw));
    float3 fw = normalize(target - ro);
    float3 rt = normalize(cross(fw, float3(0.0, 1.0, 0.0)));
    float3 up = cross(rt, fw);
    float3 rd = normalize(fw * 1.6 + uv.x * rt + uv.y * up);

    // 球体追踪：以"离最近表面距离"为步长前进，永远一步跨不过表面
    float t = 0.0;
    float d = 0.0;
    bool hit = false;
    for (int i = 0; i < 96; i++) {
        float3 p = ro + rd * t;
        d = mapScene(p);
        if (d < 0.0012 * t) { hit = true; break; }   // 距离阈值随距离放宽，省步数
        t += d;
        if (t > 30.0) { break; }
    }

    // 天空：按射线高度的竖直渐变
    float3 sky = mix(float3(0.40, 0.52, 0.70), float3(0.78, 0.86, 0.95), clamp(rd.y * 0.5 + 0.5, 0.0, 1.0));
    float3 col = sky;

    if (hit) {
        float3 p = ro + rd * t;
        float3 n = calcNormal(p);
        float3 lightDir = normalize(float3(0.55, 0.8, 0.35));

        float diff = clamp(dot(n, lightDir), 0.0, 1.0);
        float shadow = softShadow(p + n * 0.01, lightDir);
        float ao = calcAO(p, n);
        float3 base = p.y < 0.01 ? float3(0.38, 0.39, 0.42)   // 地面中灰（与天空拉开对比）
                                 : float3(0.85, 0.45, 0.35);  // 造型陶土红
        col = base * (0.18 + 0.82 * diff * shadow * ao);      // 环境项 + 漫反射 × 软阴影 × AO
        float3 halfV = normalize(lightDir - rd);
        col += pow(clamp(dot(n, halfV), 0.0, 1.0), 32.0) * shadow * 0.5;   // 高光
    }

    // 雾：随距离把颜色混向天空色，远处场景自然融进背景
    col = mix(col, sky, 1.0 - exp(-0.006 * t * t));
    return float4(pow(clamp(col, 0.0, 1.0), float3(0.4545)), 1.0);   // gamma
}
"""

let raymarchVertexSource = """
#include <metal_stdlib>
using namespace metal;

struct RaymarchVertexOut {
    float4 position [[position]];
};

vertex RaymarchVertexOut vertex_main(
    const device float2 *positions [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    RaymarchVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    return out;
}
"""

let raymarchQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

func makeRaymarchPipeline(device: MTLDevice, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let library = try! device.makeLibrary(source: raymarchVertexSource + "\n" + raymarchShaderSource, options: nil)
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

// MARK: - 窗口模式（拖拽旋转轨道相机 + 标题栏 FPS）

class RaymarchViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var yaw: Float = 0.6
    var pitch: Float = 0.22
    var lastTime: Double = 0
    var frameCount = 0
    var fpsWindowStart = CFAbsoluteTimeGetCurrent()

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = RaymarchView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? RaymarchView)?.controller = self
        queue = device.makeCommandQueue()
        pipelineState = makeRaymarchPipeline(device: device, colorFormat: metalView.colorPixelFormat)
        vertexBuffer = device.makeBuffer(
            bytes: raymarchQuad,
            length: raymarchQuad.count * MemoryLayout<SIMD2<Float>>.stride,
            options: .storageModeShared
        )
        print("Device: \(device.name)")
        print("场景：地面 + 球 + 胶囊⊗盒子的光滑并集（拖拽旋转视角）")
        print("[Pipeline ready] vertex_main + fragment_main · 96 步球体追踪 · 帧率见标题栏")
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
        var u = RaymarchUniforms(
            u0: SIMD4(yaw, pitch, 4.2, Float(now)),
            u1: SIMD4(Float(size.width), Float(size.height), 0, 0)
        )
        enc.setFragmentBytes(&u, length: MemoryLayout<RaymarchUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: raymarchQuad.count)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        frameCount += 1
        let elapsed = now - fpsWindowStart
        if elapsed >= 2.0 {
            let fps = Double(frameCount) / elapsed
            view.window?.title = String(format: "SDF Raymarch 小场景 · FPS %.0f · 拖拽旋转", fps)
            print(String(format: "FPS ≈ %.1f（标题栏同步显示）", fps))
            frameCount = 0
            fpsWindowStart = now
        }
    }
}

class RaymarchView: MTKView {
    weak var controller: RaymarchViewController?
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
        c.yaw += Float(now.x - lastMouse.x) * 0.006
        c.pitch = min(1.25, max(0.06, c.pitch + Float(now.y - lastMouse.y) * 0.006))
        lastMouse = now
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
    }
}

class RaymarchAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: RaymarchViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SDF Raymarch 小场景 · 拖拽旋转"
        window.center()
        controller = RaymarchViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 离屏导出（固定相机角度渲一帧写 PNG）

func exportRaymarchPNG(path: String, width: Int = 1920, height: Int = 1080) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let pipeline = makeRaymarchPipeline(device: device, colorFormat: .rgba8Unorm)
    let vertexBuffer = device.makeBuffer(
        bytes: raymarchQuad,
        length: raymarchQuad.count * MemoryLayout<SIMD2<Float>>.stride,
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
    var u = RaymarchUniforms(u0: SIMD4(0.6, 0.22, 4.2, 0), u1: SIMD4(Float(width), Float(height), 0, 0))
    enc.setFragmentBytes(&u, length: MemoryLayout<RaymarchUniforms>.stride, index: 1)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: raymarchQuad.count)
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
    print("场景：地面 + 球 + 胶囊⊗盒子光滑并集  尺寸 \(width)×\(height)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runRaymarch() {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        exportRaymarchPNG(path: args[i + 1])
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = RaymarchAppDelegate()
    app.delegate = delegate
    app.run()
}
