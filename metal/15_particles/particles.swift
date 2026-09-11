// 15 · GPU 粒子系统：compute 更新状态 + 渲染管线画点
// 一万个粒子全部由 GPU 更新：CPU 每帧只负责提交命令，不碰任何一个粒子
import Cocoa
import Metal
import MetalKit

class ParticlesViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var computePipeline: MTLComputePipelineState!
    var renderPipeline: MTLRenderPipelineState!
    var positionBuffer: MTLBuffer!   // 每粒子 float2 位置（NDC 空间）
    var velocityBuffer: MTLBuffer!   // 每粒子 float2 速度
    var uniformBuffer: MTLBuffer!    // 每帧的 dt
    var particleCount = 10000

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ParticleUniforms {
        float dt;
    };

    // —— compute：积分 + 边界反弹 ——
    // 把粒子想成"没有形状只有状态的小球"，一个线程管一个
    kernel void update_particles(
        device float2 *positions [[buffer(0)]],
        device float2 *velocities [[buffer(1)]],
        constant ParticleUniforms &u [[buffer(2)]],
        uint i [[thread_position_in_grid]])
    {
        float2 p = positions[i];
        float2 v = velocities[i];
        p += v * u.dt;
        // 撞墙反弹：越界就把位置夹回、速度取反
        if (p.x >  1.0) { p.x =  1.0; v.x = -abs(v.x); }
        if (p.x < -1.0) { p.x = -1.0; v.x =  abs(v.x); }
        if (p.y >  1.0) { p.y =  1.0; v.y = -abs(v.y); }
        if (p.y < -1.0) { p.y = -1.0; v.y =  abs(v.y); }
        positions[i] = p;
        velocities[i] = v;
    }

    struct PointOut {
        float4 position [[position]];
        float  pointSize [[point_size]];
        float4 color;
    };

    // —— render：每个粒子画成一个点，颜色按速度渐变 ——
    vertex PointOut vertex_main(
        device const float2 *positions [[buffer(0)]],
        device const float2 *velocities [[buffer(1)]],
        uint vid [[vertex_id]])
    {
        PointOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.pointSize = 2.0;
        float speed = length(velocities[vid]);
        // 慢=青，快=橙红：颜色编码速度，运动状态一眼可读
        float t = clamp(speed / 1.2, 0.0, 1.0);
        out.color = float4(0.2 + 0.85 * t, 0.9 - 0.5 * t, 1.0 - 0.85 * t, 1.0);
        return out;
    }

    fragment float4 fragment_main(PointOut in [[stage_in]]) {
        return in.color;
    }
    """

    override func viewDidLoad() {
        super.viewDidLoad()
        let v = MTKView(frame: view.bounds, device: MTLCreateSystemDefaultDevice())
        v.autoresizingMask = [.width, .height]
        view.addSubview(v)
        device = v.device
        commandQueue = device.makeCommandQueue()
        v.delegate = self
        v.clearColor = MTLClearColor(red: 0.05, green: 0.06, blue: 0.1, alpha: 1)

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            computePipeline = try device.makeComputePipelineState(
                function: library.makeFunction(name: "update_particles")!)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vertex_main")
            desc.fragmentFunction = library.makeFunction(name: "fragment_main")
            desc.colorAttachments[0].pixelFormat = v.colorPixelFormat
            renderPipeline = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("管线创建失败: \(error)"); exit(1)
        }

        // 初始状态：位置聚在中心附近、方向随机（固定种子，结果可复现）
        var seed: UInt64 = 2026
        func rand() -> Float {   // 简易可复现伪随机
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float((seed >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
        }
        var pos = [SIMD2<Float>](), vel = [SIMD2<Float>]()
        for _ in 0..<particleCount {
            pos.append(SIMD2(rand() * 0.4 - 0.2, rand() * 0.4 - 0.2))
            let a = rand() * 2 * Float.pi
            let s = 0.15 + rand() * 0.8
            vel.append(SIMD2(cos(a) * s, sin(a) * s))
        }
        positionBuffer = device.makeBuffer(bytes: pos, length: particleCount * 8)
        velocityBuffer = device.makeBuffer(bytes: vel, length: particleCount * 8)
        uniformBuffer = device.makeBuffer(length: 4)
        print("粒子数: \(particleCount)，compute 每帧更新位置/速度，render 画 \(particleCount) 个点")
    }

    func draw(in view: MTKView) {
        // 每帧 dt≈1/60：dt 是 compute 的唯一"时间感"来源
        var dt: Float = 1.0 / 60.0
        memcpy(uniformBuffer.contents(), &dt, 4)

        guard let cb = commandQueue.makeCommandBuffer() else { return }

        // Pass 1 —— compute：积分一帧
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(computePipeline)
            enc.setBuffer(positionBuffer, offset: 0, index: 0)
            enc.setBuffer(velocityBuffer, offset: 0, index: 1)
            enc.setBuffer(uniformBuffer, offset: 0, index: 2)
            let group = MTLSize(width: 256, height: 1, depth: 1)
            let groups = MTLSize(width: (particleCount + 255) / 256, height: 1, depth: 1)
            enc.dispatchThreadgroups(groups, threadsPerThreadgroup: group)
            enc.endEncoding()
        }

        // Pass 2 —— render：把新位置画出来
        // 同一个 commandBuffer 内 compute 自动先于 render 完成——GPU 时间线的顺序保证
        if let drawable = view.currentDrawable,
           let pass = view.currentRenderPassDescriptor,
           let enc = cb.makeRenderCommandEncoder(descriptor: pass) {
            enc.setRenderPipelineState(renderPipeline)
            enc.setVertexBuffer(positionBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(velocityBuffer, offset: 0, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
            enc.endEncoding()
        }
        cb.present(view.currentDrawable!)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

class ParticlesAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 15 · GPU Particles (10000)"
        window.center()
        window.contentViewController = ParticlesViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runParticles() {
    let app = NSApplication.shared
    let delegate = ParticlesAppDelegate()
    app.delegate = delegate
    app.run()
}
