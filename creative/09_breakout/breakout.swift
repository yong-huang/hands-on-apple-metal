import Cocoa
import simd
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// 游戏逻辑尺寸（逻辑像素），渲染与物理都基于它
let gameW: Float = 800
let gameH: Float = 600

// ---- 游戏状态（纯 CPU 逻辑，可无人值守快进）----

enum BreakoutState {
    case serving   // 球粘在拍上，等待发射
    case playing
    case win
    case gameover
}

struct Brick {
    var x: Float, y: Float, w: Float, h: Float
    var color: SIMD4<Float>
    var alive = true
}

struct BreakoutGame {
    var state: BreakoutState = .serving
    var paddleX: Float = gameW / 2
    let paddleW: Float = 110, paddleH: Float = 14, paddleY: Float = 560
    var ballPos = SIMD2<Float>(gameW / 2, 540)
    var ballVel = SIMD2<Float>(0, 0)
    var lives = 3
    var score = 0
    var tier = 0                          // 胜利后重开的球速档位
    var bricks: [Brick] = []
    var livesLost = 0                     // 测试用计数
    var rngState: UInt32 = 0x9E3779B9     // 固定种子的 LCG：抖动可复现

    init() { resetBricks(); serve() }

    mutating func resetBricks() {
        bricks.removeAll()
        let cols = 12, rows = 6
        let bw: Float = 60, bh: Float = 18
        let gap: Float = 4
        let totalW = Float(cols) * bw + Float(cols - 1) * gap
        let x0 = (gameW - totalW) / 2
        let rowColors: [SIMD4<Float>] = [
            SIMD4(0.90, 0.35, 0.30, 1), SIMD4(0.95, 0.60, 0.25, 1), SIMD4(0.95, 0.85, 0.30, 1),
            SIMD4(0.45, 0.80, 0.40, 1), SIMD4(0.35, 0.60, 0.92, 1), SIMD4(0.70, 0.45, 0.90, 1),
        ]
        for r in 0..<rows {
            for c in 0..<cols {
                let x = x0 + Float(c) * (bw + gap)
                let y = 60 + Float(r) * (bh + gap)
                bricks.append(Brick(x: x, y: y, w: bw, h: bh, color: rowColors[r]))
            }
        }
    }

    var ballSpeed: Float { 320 + Float(tier) * 40 + Float(score) * 1.2 }

    mutating func serve() {
        ballPos = SIMD2(paddleX, paddleY - 20)
        let angle = Float(-0.35)   // 固定偏角发射（确定性，验收需要）
        ballVel = ballSpeed * SIMD2(sin(angle), -cos(angle))
        state = .playing
    }

    var aliveBricks: Int { bricks.filter(\.alive).count }

    // 小角度抖动（固定种子 LCG，可复现）：打破"垂直弹"与"砖后口袋"两种死循环
    mutating func jitterVelocity() {
        rngState = rngState &* 1664525 &+ 1013904223
        let jitter = (Float(rngState % 1000) / 1000.0 - 0.5) * 0.15
        let c = cos(jitter), sn = sin(jitter)
        ballVel = SIMD2(ballVel.x * c - ballVel.y * sn, ballVel.x * sn + ballVel.y * c)
    }

    // 单步物理：子步进防隧穿（球速最高约 520 px/s，每子步位移 < 3 px，远小于拍高 14 px）
    mutating func step(dt: Float) {
        guard state == .playing else { return }
        let sub = 4
        let h = dt / Float(sub)
        for _ in 0..<sub {
            ballPos += ballVel / simd_length(ballVel) * ballSpeed * h
            // 墙壁
            if ballPos.x < 7 { ballPos.x = 7; ballVel.x = abs(ballVel.x) }
            if ballPos.x > gameW - 7 { ballPos.x = gameW - 7; ballVel.x = -abs(ballVel.x) }
            if ballPos.y < 7 { ballPos.y = 7; ballVel.y = abs(ballVel.y) }
            // 球拍：仅当球向下运动且触及拍面时反弹，反弹角由命中位置决定
            if ballVel.y > 0, ballPos.y + 7 >= paddleY, ballPos.y - 7 <= paddleY + paddleH,
               ballPos.x >= paddleX - paddleW / 2 - 7, ballPos.x <= paddleX + paddleW / 2 + 7 {
                ballPos.y = paddleY - 7
                let offset = (ballPos.x - paddleX) / (paddleW / 2)      // -1..1
                let angle = offset * 1.05                                // 最大约 60°
                let v = simd_length(ballVel)
                ballVel = v * SIMD2(sin(angle), -cos(angle))
                jitterVelocity()   // 自动追踪会让命中点恒居中→笔直上行，抖动让球横向游走
            }
            // 落底：丢命或结束
            if ballPos.y > gameH + 14 {
                livesLost += 1
                lives -= 1
                if lives <= 0 {
                    state = .gameover
                } else {
                    state = .serving
                }
                return
            }
            // 砖块：圆 vs AABB，取穿透最浅的轴反弹
            for i in bricks.indices where bricks[i].alive {
                let b = bricks[i]
                let cx = max(b.x, min(ballPos.x, b.x + b.w))
                let cy = max(b.y, min(ballPos.y, b.y + b.h))
                let dx = ballPos.x - cx, dy = ballPos.y - cy
                if dx * dx + dy * dy <= 49 {
                    bricks[i].alive = false
                    score += 1
                    ballVel = ballVel * (ballSpeed / simd_length(ballVel))   // 砖块数递增 → 球速跟涨
                    if abs(dx) > abs(dy) { ballVel.x = abs(ballVel.x) * (dx > 0 ? 1 : -1) }
                    else { ballVel.y = abs(ballVel.y) * (dy > 0 ? 1 : -1) }
                    jitterVelocity()
                    if aliveBricks == 0 { state = .win }
                    break
                }
            }
            if state != .playing { return }
            // 防水平死循环：|vy| 低于球速 25% 时抬到 25%（保持速率不变，只转方向）
            let v = simd_length(ballVel)
            let minVy = v * 0.25
            if abs(ballVel.y) < minVy {
                let sign: Float = ballVel.y >= 0 ? 1 : -1
                ballVel.y = sign * minVy
                let vx = sqrt(max(v * v - ballVel.y * ballVel.y, 0))
                ballVel.x = (ballVel.x >= 0 ? 1 : -1) * vx
            }
        }
    }
}

// ---- 渲染 ----

// 每个实例：中心 + 半尺寸 + 颜色（32 字节）
struct BreakoutInstance {
    var pos: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

let breakoutVertexSource = """
#include <metal_stdlib>
using namespace metal;

struct BreakoutInstance {
    float2 pos;
    float2 size;
    float4 color;
};

struct BreakoutVertexOut {
    float4 position [[position]];
    float4 color;
    float2 local;      // 0~1 的单元四边形坐标，片元里做圆角/圆形
};

vertex BreakoutVertexOut vertex_main(
    const device float2 *corners [[buffer(0)]],
    const device BreakoutInstance *instances [[buffer(1)]],
    constant float2 &gameRes [[buffer(2)]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]]
) {
    BreakoutInstance inst = instances[iid];
    float2 world = inst.pos + corners[vid] * inst.size;
    // 逻辑像素 → NDC；游戏坐标 y 向下，需翻转
    float2 ndc = float2(world.x / gameRes.x * 2.0 - 1.0, 1.0 - world.y / gameRes.y * 2.0);
    BreakoutVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = inst.color;
    out.local = corners[vid];
    return out;
}
"""

let breakoutRectSource = """
#include <metal_stdlib>
using namespace metal;

fragment float4 rect_fragment(BreakoutVertexOut in [[stage_in]]) {
    // 圆角矩形：到中心归一化距离的简易 SDF
    float2 d = abs(in.local - 0.5) - 0.44;
    float sdf = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
    if (sdf > 0.0) { discard_fragment(); }
    return in.color;
}
"""

let breakoutBallSource = """
#include <metal_stdlib>
using namespace metal;

fragment float4 ball_fragment(BreakoutVertexOut in [[stage_in]]) {
    float d = length(in.local - 0.5) * 2.0;   // 0 在圆心，1 在边
    if (d > 1.0) { discard_fragment(); }
    float shade = 0.75 + 0.45 * (1.0 - d);
    return float4(in.color.rgb * shade, 1.0);
}
"""

let breakoutCorners: [SIMD2<Float>] = [
    SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1),
    SIMD2(0, 1), SIMD2(1, 0), SIMD2(1, 1),
]

func makeBreakoutPipeline(device: MTLDevice, fragmentName: String, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let library = try! device.makeLibrary(source: breakoutVertexSource + "\n" + (fragmentName == "rect" ? breakoutRectSource : breakoutBallSource), options: nil)
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = library.makeFunction(name: "vertex_main")
    desc.fragmentFunction = library.makeFunction(name: fragmentName + "_fragment")
    desc.colorAttachments[0].pixelFormat = colorFormat
    return try! device.makeRenderPipelineState(descriptor: desc)
}

// 收集当前帧的全部实例（砖块 + 拍 + 球 + 服务提示条）
func collectInstances(game: BreakoutGame) -> [BreakoutInstance] {
    var inst: [BreakoutInstance] = []
    for b in game.bricks where b.alive {
        inst.append(BreakoutInstance(pos: SIMD2(b.x, b.y), size: SIMD2(b.w, b.h), color: b.color))
    }
    let paddleColor: SIMD4<Float> = game.state == .win ? SIMD4(0.5, 0.9, 0.5, 1) : SIMD4(0.92, 0.92, 0.95, 1)
    inst.append(BreakoutInstance(pos: SIMD2(game.paddleX - game.paddleW / 2, game.paddleY), size: SIMD2(game.paddleW, game.paddleH), color: paddleColor))
    if game.state != .win && game.state != .gameover {
        let ballColor: SIMD4<Float> = game.state == .serving ? SIMD4(0.95, 0.75, 0.35, 1) : SIMD4(0.98, 0.90, 0.60, 1)
        inst.append(BreakoutInstance(pos: game.ballPos - SIMD2(7, 7), size: SIMD2(14, 14), color: ballColor))
    }
    return inst
}

func encodeBreakoutFrame(encoder: MTLRenderCommandEncoder, rectPS: MTLRenderPipelineState, ballPS: MTLRenderPipelineState,
                         rectBuffer: MTLBuffer, ballBuffer: MTLBuffer, cornersBuffer: MTLBuffer,
                         rectCount: Int, ballCount: Int, gameRes: inout SIMD2<Float>) {
    var res = gameRes
    encoder.setRenderPipelineState(rectPS)
    encoder.setVertexBuffer(cornersBuffer, offset: 0, index: 0)
    encoder.setVertexBuffer(rectBuffer, offset: 0, index: 1)
    encoder.setVertexBytes(&res, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: rectCount)
    encoder.setRenderPipelineState(ballPS)
    encoder.setVertexBuffer(ballBuffer, offset: 0, index: 1)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: ballCount)
}

// MARK: - 窗口模式

class BreakoutViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var queue: MTLCommandQueue!
    var rectPS: MTLRenderPipelineState!
    var ballPS: MTLRenderPipelineState!
    var cornersBuffer: MTLBuffer!
    var rectBuffer: MTLBuffer!
    var ballBuffer: MTLBuffer!
    var game = BreakoutGame()

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("本机不支持 Metal")
        }
        self.device = device
        metalView = BreakoutView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), device: device)
        metalView.delegate = self
        metalView.preferredFramesPerSecond = 60
        view = metalView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        (metalView as? BreakoutView)?.controller = self
        queue = device.makeCommandQueue()
        rectPS = makeBreakoutPipeline(device: device, fragmentName: "rect", colorFormat: metalView.colorPixelFormat)
        ballPS = makeBreakoutPipeline(device: device, fragmentName: "ball", colorFormat: metalView.colorPixelFormat)
        cornersBuffer = device.makeBuffer(bytes: breakoutCorners, length: breakoutCorners.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
        rectBuffer = device.makeBuffer(length: 128 * MemoryLayout<BreakoutInstance>.stride, options: .storageModeShared)
        ballBuffer = device.makeBuffer(length: 4 * MemoryLayout<BreakoutInstance>.stride, options: .storageModeShared)
        print("Device: \(device.name)")
        print("打砖块：鼠标移动控拍 · 点击发射 · R 重开（胜利后球速档位 +1）· 生命 3")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(metalView)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        game.step(dt: 1.0 / 60.0)
        if game.state == .win {
            view.window?.title = "WIN！砖块全清 · 按 R 进入球速档 \(game.tier + 1)"
        } else if game.state == .gameover {
            view.window?.title = "GAME OVER · 得分 \(game.score) · 按 R 重开"
        } else {
            view.window?.title = "打砖块 · 得分 \(game.score) · 生命 \(game.lives) · 档位 \(game.tier)"
        }

        let instances = collectInstances(game: game)
        // 顺序：砖 + 拍在前，球（仅 serving/playing 状态存在）在最后
        let rectCount = instances.count - (game.state == .serving || game.state == .playing ? 1 : 0)
        let rectData = Array(instances[0..<rectCount])
        let ballData = game.state == .serving || game.state == .playing ? [instances[instances.count - 1]] : []
        rectBuffer.contents().copyMemory(from: rectData, byteCount: rectData.count * MemoryLayout<BreakoutInstance>.stride)
        ballBuffer.contents().copyMemory(from: ballData, byteCount: ballData.count * MemoryLayout<BreakoutInstance>.stride)

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var logicalRes = SIMD2(gameW, gameH)
        encodeBreakoutFrame(encoder: enc, rectPS: rectPS, ballPS: ballPS,
                            rectBuffer: rectBuffer, ballBuffer: ballBuffer, cornersBuffer: cornersBuffer,
                            rectCount: rectData.count, ballCount: ballData.count, gameRes: &logicalRes)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

class BreakoutView: MTKView {
    weak var controller: BreakoutViewController?

    override var acceptsFirstResponder: Bool { true }

    override func mouseMoved(with event: NSEvent) {
        guard let c = controller else { return }
        let p = convert(event.locationInWindow, from: nil)
        c.game.paddleX = min(gameW - c.game.paddleW / 2, max(c.game.paddleW / 2, Float(p.x)))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        if c.game.state == .serving { c.game.serve() }
    }

    override func keyDown(with event: NSEvent) {
        guard let c = controller else { return super.keyDown(with: event) }
        if event.keyCode == 49, c.game.state == .serving {         // 空格发射
            c.game.serve()
        } else if event.keyCode == 15 {                             // R
            let wasWin = c.game.state == .win
            c.game = BreakoutGame()
            if wasWin { c.game.tier = c.game.tier + 1 }             // 胜利重开升档
            print("重开：球速档位 \(c.game.tier)")
        } else {
            super.keyDown(with: event)
        }
    }
}

class BreakoutAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var controller: BreakoutViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "打砖块 · 移动鼠标控拍 点击发射"
        window.center()
        controller = BreakoutViewController()
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.acceptsMouseMovedEvents = true
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - test（无人值守两条验收断言）与导出

// 断言一：自动追踪 AI 完整通关（砖全清 → WIN）；断言二：空闲拍恰丢 3 命 → GAMEOVER
func breakoutTest() {
    // 断言一：完美拍（每帧对齐球的 x），高球速档 5 施压子步进
    var g = BreakoutGame()
    g.tier = 5
    var frames = 0
    while g.state != .win && g.state != .gameover && frames < 40000 {
        g.paddleX = max(g.paddleW / 2, min(gameW - g.paddleW / 2, g.ballPos.x))
        if g.state == .serving { g.serve() }
        g.step(dt: 1.0 / 60.0)
        frames += 1
    }
    let a1 = g.state == .win
    print("断言一（自动追踪通关，档位 5）：\(g.state == .win ? "WIN" : "\(g.state)") · 用时 \(frames) 帧 · 剩余砖 \(g.aliveBricks) · 得分 \(g.score)")
    print(a1 ? "✅ 通过：砖全清进入 WIN" : "❌ 未通过")

    // 断言二：拍完全不动，球应 3 次落底后 GAMEOVER（验证丢命与状态机，顺带覆盖落底判定）
    var g2 = BreakoutGame()
    g2.tier = 8
    var frames2 = 0
    while g2.state != .gameover && frames2 < 40000 {
        if g2.state == .serving { g2.serve() }
        g2.step(dt: 1.0 / 60.0)
        frames2 += 1
    }
    let a2 = g2.state == .gameover && g2.livesLost == 3 && g2.lives == 0
    print("断言二（空闲拍丢命，档位 8）：终态 \(g2.state == .gameover ? "GAMEOVER" : "\(g2.state)") · 丢命 \(g2.livesLost) 次 · 剩余生命 \(g2.lives)")
    print(a2 ? "✅ 通过：恰丢 3 命进入 GAMEOVER" : "❌ 未通过")
    print(a1 && a2 ? "✅ 验收全部通过" : "❌ 验收未全部通过")
    exit(a1 && a2 ? 0 : 1)
}

func exportBreakoutPNG(path: String, width: Int = 800, height: Int = 600) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let rectPS = makeBreakoutPipeline(device: device, fragmentName: "rect", colorFormat: .rgba8Unorm)
    let ballPS = makeBreakoutPipeline(device: device, fragmentName: "ball", colorFormat: .rgba8Unorm)
    var game = BreakoutGame()
    game.state = .playing
    game.ballVel = game.ballSpeed * SIMD2(sin(-0.35), -cos(-0.35))
    var instances = collectInstances(game: game)
    let ballData = [instances.removeLast()]
    let rectData = instances

    let cornersBuffer = device.makeBuffer(bytes: breakoutCorners, length: breakoutCorners.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
    let rectBuffer = device.makeBuffer(bytes: rectData, length: rectData.count * MemoryLayout<BreakoutInstance>.stride, options: .storageModeShared)
    let ballBuffer = device.makeBuffer(bytes: ballData, length: ballData.count * MemoryLayout<BreakoutInstance>.stride, options: .storageModeShared)

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
    var logical = SIMD2(gameW, gameH)
    encodeBreakoutFrame(encoder: enc, rectPS: rectPS, ballPS: ballPS,
                        rectBuffer: rectBuffer!, ballBuffer: ballBuffer!, cornersBuffer: cornersBuffer!,
                        rectCount: rectData.count, ballCount: ballData.count, gameRes: &logical)
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
    print("开局画面：72 砖 + 拍 + 球  尺寸 \(width)×\(height)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

// MARK: - 入口

func runBreakout() {
    let args = CommandLine.arguments
    if args.contains("test") {
        breakoutTest()
        exit(0)   // 不可达：breakoutTest 内部 exit
    }
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        exportBreakoutPNG(path: args[i + 1])
        exit(0)
    }

    let app = NSApplication.shared
    app.setActivationPolicy(.regular)   // 未打包的命令行进程默认无 GUI 策略，不设 regular 窗口不显示
    let delegate = BreakoutAppDelegate()
    app.delegate = delegate
    app.run()
}
