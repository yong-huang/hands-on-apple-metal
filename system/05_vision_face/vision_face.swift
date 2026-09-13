// 05 · Vision 人脸检测 → Metal 实时马赛克
// 相机帧 → Vision 检测人脸（归一化矩形）→ Metal fragment 对人脸区域打马赛克。
// 无相机授权时回退合成帧并做全画面马赛克，管线验证不被阻塞。
import SwiftUI
import AVFoundation
import Vision
import Metal
import MetalKit

// MARK: - 渲染视图：相机 + 人脸检测 + 马赛克
final class VisionFaceView: NSView, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let maxFaces = 8

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        uint  faceCount;                  // 检出的人脸数
        float time;
        float4 rects[8];                  // 每张脸：xy=左上(归一化,镜像后) zw=宽高
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
        float4 c = cam.sample(camSmp, uv);

        // 对每张检出的人脸矩形打马赛克：量化到块中心再采样
        for (uint i = 0; i < u.faceCount; i++) {
            float4 r = u.rects[i];
            if (uv.x >= r.x && uv.x <= r.x + r.z &&
                uv.y >= r.y && uv.y <= r.y + r.w) {
                float2 blockSize = float2(0.016, 0.028);
                float2 local = (uv - r.xy) / blockSize;
                float2 blocked = (floor(local) + 0.5) * blockSize + r.xy;
                c = cam.sample(camSmp, blocked);
            }
        }
        return c;
    }
    """

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var textureCache: CVMetalTextureCache!
    var uniformBuffer: MTLBuffer!
    var session: AVCaptureSession!               // 强持有：局部变量会在返回后释放、相机熄灭
    var frames = 0, fpsStart = Date()
    var faceRequest: VNDetectFaceRectanglesRequest!

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        wantsLayer = true
        layer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false       // 马赛克要回读采样

        let library = try! device.makeLibrary(source: Self.shaderSource, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "vertex_main")
        desc.fragmentFunction = library.makeFunction(name: "fragment_main")
        desc.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
        pipelineState = try! device.makeRenderPipelineState(descriptor: desc)

        // uniform：faceCount + time + 8×float4 矩形
        uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.stride)

        faceRequest = VNDetectFaceRectanglesRequest()
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision2

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        textureCache = cache!

        syncDrawableSize()
        setupCamera()
    }

    required init?(coder: NSCoder) { fatalError("不走 IB") }

    override func layout() {
        super.layout()
        metalLayer.drawableSize = convertToBacking(metalLayer.bounds.size)
    }

    func syncDrawableSize() {
        metalLayer.drawableSize = convertToBacking(metalLayer.bounds.size)
    }

    // MARK: - 相机会话（复用 03 的权限与回退模式）
    func setupCamera() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] ok in
                DispatchQueue.main.async {
                    if ok { self?.startSession() }
                    else { self?.startSynthetic() }
                }
            }
        default:
            startSynthetic()
        }
    }

    func startSession() {
        guard let camDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified),
              let input = try? AVCaptureDeviceInput(device: camDevice) else {
            startSynthetic(); return
        }
        let newSession = AVCaptureSession()
        newSession.sessionPreset = .hd1280x720
        newSession.beginConfiguration()
        newSession.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera.frames"))
        newSession.addOutput(output)
        newSession.commitConfiguration()
        self.session = newSession                 // 强持有：不写这行相机会两秒后熄灭
        newSession.startRunning()
        print("相机已启动，检测到的人脸将实时打马赛克")
    }

    // 合成帧回退：全画面马赛克验证管线（合成图案上 Vision 检不出人脸）
    var synthTimer: Timer?
    var synthFrame: UInt32 = 0

    func startSynthetic() {
        print("⚠️ 相机不可用（未授权），回退合成帧 + 全画面马赛克验证管线")
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return }
        synthTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
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
            render(pixelBuffer: buffer, time: Double(synthFrame) / 30.0, faceCount: 0)
        }
    }

    // MARK: - 每帧：Vision 检测 → 渲染（含马赛克）
    struct Uniforms {
        var faceCount: UInt32
        var time: Float
        var rects: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    }

    var lastFaceCount = -1

    func render(pixelBuffer: CVPixelBuffer, time: Double, faceCount: Int, rects: [SIMD4<Float>] = []) {
        // 像素缓冲 → Metal 纹理（零拷贝；须 IOSurface 支持，见 03）
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        var tex: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &tex)
        guard st == kCVReturnSuccess, let cvTex = tex,
              let camTex = CVMetalTextureGetTexture(cvTex),
              let drawable = metalLayer.nextDrawable() else { return }

        // uniform：8 个 float4 槽位（不足补零）
        var u = Uniforms(faceCount: UInt32(faceCount), time: Float(time),
                         rects: (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero))
        withUnsafeMutableBytes(of: &u.rects) { ptr in
            for (i, r) in rects.prefix(8).enumerated() {
                ptr.storeBytes(of: r, toByteOffset: i * 16, as: SIMD4<Float>.self)
            }
        }
        memcpy(uniformBuffer.contents(), &u, MemoryLayout<Uniforms>.stride)

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
            print(String(format: "处理帧率: %d fps（检出人脸：%d）", frames, faceCount))
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

    // 相机回调：Vision 检测（后台队列）→ 主线程渲染
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        // Vision 人脸检测（同步跑在相机回调队列，不占主线程）
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        try? handler.perform([faceRequest!])
        let faces = (faceRequest.results ?? []).prefix(8)

        // Vision 归一化矩形（origin 左下）→ 镜像后矩形（origin 左上，与 shader uv 一致）
        var rects = [SIMD4<Float>]()
        for face in faces {
            let b = face.boundingBox
            let my: Float = 1.0 - Float(b.origin.y) - Float(b.height)  // y 翻转到底部起
            rects.append(SIMD4(Float(b.origin.x), my, Float(b.width), Float(b.height)))
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.render(pixelBuffer: pb, time: seconds, faceCount: faces.count, rects: rects)
        }
    }

}

// MARK: - SwiftUI 桥接
struct VisionFaceViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> VisionFaceView { VisionFaceView(frame: .zero) }
    func updateNSView(_ view: VisionFaceView, context: Context) {}
}

struct ContentView: View {
    var body: some View {
        VisionFaceViewRepresentable()
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                Text("Vision 人脸检测 → Metal 马赛克（对准你的脸）")
                    .padding(6).background(.black.opacity(0.5))
                    .foregroundStyle(.white).font(.callout)
            }
    }
}

@main
struct VisionFaceApp: App {
    init() {
        if let s = ProcessInfo.processInfo.environment["AUTO_QUIT"], let t = Double(s), t > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }
    }
    var body: some Scene {
        WindowGroup { ContentView().frame(width: 960, height: 580) }
    }
}
