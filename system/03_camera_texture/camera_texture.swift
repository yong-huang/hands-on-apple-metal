// 03 · 相机实时滤镜：AVFoundation → CVMetalTextureCache → Metal
// 相机像素缓冲零拷贝转 Metal 纹理，fragment 内四种滤镜实时切换。
// 滤镜选择由 SwiftUI 状态驱动（按钮/按键均可），经 updateNSView 传入渲染视图。
// 权限：首次运行弹窗授权相机；被拒时自动回退合成测试帧。
import SwiftUI
import AVFoundation
import Metal
import MetalKit

// MARK: - 渲染视图：相机纹理 + 滤镜 fragment
final class CameraFilterView: NSView, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let filterNames = ["原图（镜像）", "黑白", "反色", "漫画量化"]

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        uint  filter;
        float time;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut vertex_main(uint vid [[vertex_id]]) {
        float2 pos[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        float2 uv[3]  = { float2(0, 1), float2(2, 1), float2(0, -1) };
        return VertexOut { float4(pos[vid], 0.0, 1.0), uv[vid] };
    }

    fragment float4 fragment_main(
        VertexOut in [[stage_in]],
        texture2d<float> cam [[texture(0)]],
        sampler camSmp [[sampler(0)]],
        constant Uniforms &u [[buffer(0)]])
    {
        float2 uv = in.uv;
        uv.x = 1.0 - uv.x;                        // 前置摄像头镜像
        float4 c = cam.sample(camSmp, uv);
        switch (u.filter) {
            case 1: {                              // 黑白
                float l = dot(c.rgb, float3(0.299, 0.587, 0.114));
                return float4(l);
            }
            case 2: {                              // 反色
                return float4(1.0 - c.rgb, 1.0);
            }
            case 3: {                              // 漫画：量化 + 边缘
                float steps = 4.0;
                float3 q = floor(c.rgb * steps) / steps;
                float gx = cam.sample(camSmp, uv + float2( 1.0/720.0, 0)).r
                         - cam.sample(camSmp, uv - float2( 1.0/720.0, 0)).r;
                float gy = cam.sample(camSmp, uv + float2(0, 1.0/720.0)).r
                         - cam.sample(camSmp, uv - float2(0, 1.0/720.0)).r;
                float edge = saturate((abs(gx) + abs(gy)) * 6.0);
                return float4(mix(q, float3(0.05), edge), 1.0);
            }
            default:
                return c;
        }
    }
    """

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var textureCache: CVMetalTextureCache!
    var uniformBuffer: MTLBuffer!
    var session: AVCaptureSession!       // 必须强持有：局部变量会在函数返回后被释放、相机熄灭
    var filterIndex: UInt32 = 0          // 0 原图 1 黑白 2 反色 3 漫画
    var frames = 0, fpsStart = Date()
    var cameraActive = false             // 真实相机帧到手后才置 true
    var filterChangeLog: ((String) -> Void)?

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        wantsLayer = true
        layer = CAMetalLayer()                              // 直接替换图层实例
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false                  // fragment 要回读采样，不能只作呈现
        metalLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        let library = try! device.makeLibrary(source: Self.shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vertex_main")
        desc.fragmentFunction = library.makeFunction(name: "fragment_main")
        desc.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
        pipelineState = try! device.makeRenderPipelineState(descriptor: desc)

        uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache!

        syncDrawableSize()
        startSynthetic()          // 先跑合成帧——窗口从第一帧起就有内容
        setupCamera()             // 授权通过后自动切真相机
    }

    required init?(coder: NSCoder) { fatalError("不走 IB") }

    override func layout() {
        super.layout()
        metalLayer.drawableSize = convertToBacking(metalLayer.bounds.size)
    }

    func syncDrawableSize() {
        metalLayer.drawableSize = convertToBacking(metalLayer.bounds.size)
    }

    // MARK: - 相机会话（权限 → 配置 → 启动；被拒自动回退合成帧）
    func setupCamera() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            switchToCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { self?.switchToCamera() }
                    else { print("相机权限被拒，继续使用合成帧") }
                }
            }
        default:
            print("相机权限被拒，继续使用合成帧")
        }
    }

    func switchToCamera() {
        startSession()                   // 合成帧继续跑，等第一帧真相机帧到手才停
    }

    func stopSynthetic() {
        synthTimer?.invalidate(); synthTimer = nil
    }

    func startSession() {
        guard let camDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified),
              let input = try? AVCaptureDeviceInput(device: camDevice) else {
            startSynthetic(); return
        }
        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720
        self.session = session
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.frames"))
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        print("相机已启动，点击滤镜按钮或按 1-4 切换")
    }

    // 合成帧回退：运动测试图案走与相机完全相同的渲染管线（权限不可用时自动接管）
    var synthTimer: Timer?
    var synthFrame: UInt32 = 0

    func startSynthetic() {
        print("⚠️ 相机不可用（未授权），回退合成测试帧——管线验证不受影响")
        var pb: CVPixelBuffer?
        // IOSurface 声明是硬要求：缺失则纹理创建返回 -6660
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return }
        synthTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, !cameraActive else { return }   // 相机帧到手后合成帧自动让位
            synthFrame &+= 1
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                let t = Float(synthFrame)
                for y in stride(from: 0, to: 720, by: 4) {
                    for x in stride(from: 0, to: 1280, by: 4) {
                        let v = UInt8(127 + 127 * sin(Float(x) * 0.02 + t * 0.1)
                                          * cos(Float(y) * 0.015 - t * 0.07))
                        for dy in 0..<4 { for dx in 0..<4 {
                            let o = ((y + dy) * 1280 + (x + dx)) * 4
                            ptr[o] = v; ptr[o+1] = UInt8(255 - v); ptr[o+2] = UInt8(v / 2)
                            ptr[o+3] = 255
                        } }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            render(pixelBuffer: buffer, time: Double(synthFrame) / 30.0)
        }
    }

    // MARK: - 每帧：渲染（相机回调或合成帧均走此路径）
    struct Uniforms {
        var filter: UInt32
        var time: Float
    }

    func render(pixelBuffer: CVPixelBuffer, time: Double) {
        // 像素缓冲 → Metal 纹理（CVMetalTextureCache 零拷贝）
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        var tex: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &tex)
        guard st == kCVReturnSuccess, let cvTex = tex,
              let camTex = CVMetalTextureGetTexture(cvTex),
              let drawable = metalLayer.nextDrawable() else { return }
        var uniforms = Uniforms(filter: filterIndex, time: Float(time))
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.stride)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentTexture(camTex, index: 0)
        enc.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        frames += 1
        if Date().timeIntervalSince(fpsStart) >= 1.0 {
            print(String(format: "处理帧率: %d fps（当前滤镜：%@）",
                         frames, Self.filterNames[Int(filterIndex)]))
            frames = 0; fpsStart = Date()
        }
    }

    nonisolated func createTexture(from pb: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var tex: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &tex)
        guard r == kCVReturnSuccess else { return nil }
        return CVMetalTextureGetTexture(tex!)
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !cameraActive {
                cameraActive = true
                FileHandle.standardError.write("【诊断】captureOutput 已投递主线程\n".data(using: .utf8)!)
                stopSynthetic()              // 真实帧到手那一刻才停合成帧——零空窗切换
                print("相机帧已接管画面（合成帧停止）")
            }
            render(pixelBuffer: pb, time: seconds)
        }
    }
}

// MARK: - SwiftUI 桥接：滤镜编号由 @State 驱动（updateNSView 写入渲染视图）
struct CameraViewRepresentable: NSViewRepresentable {
    let filterIndex: UInt32
    var onFilterChange: ((String) -> Void)?

    func makeNSView(context: Context) -> CameraFilterView {
        let v = CameraFilterView(frame: .zero)
        v.filterChangeLog = onFilterChange
        v.filterIndex = filterIndex
        return v
    }
    func updateNSView(_ view: CameraFilterView, context: Context) {
        view.filterIndex = filterIndex
    }
}

struct ContentView: View {
    @State private var filter: UInt32 = 0
    @State private var keyMonitor: Any?
    private let names = ["原图（镜像）", "黑白", "反色", "漫画量化"]

    var body: some View {
        VStack(spacing: 0) {
            CameraViewRepresentable(filterIndex: filter)
                .ignoresSafeArea()
            HStack(spacing: 10) {
                ForEach(0..<4, id: \.self) { i in
                    Button("\(i + 1)·\(names[i])") { filter = UInt32(i) }
                        .buttonStyle(.borderedProminent)
                        .tint(filter == UInt32(i) ? .blue : .gray)
                }
            }
            .padding(10)
        }
        .frame(width: 960, height: 620)
        .onAppear {
            // 键盘 1-4 同样可切：本地事件监听改 @State
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    guard let c = e.charactersIgnoringModifiers,
                          let n = UInt32(c), (1...4).contains(n) else { return e }
                    DispatchQueue.main.async { filter = n - 1 }
                    return nil
                }
            }
        }
    }
}

@main
struct CameraFilterApp: App {
    init() {
        if let s = ProcessInfo.processInfo.environment["AUTO_QUIT"], let t = Double(s), t > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }
    }
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
