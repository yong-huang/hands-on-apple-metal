// 07 · IOSurface 跨框架零拷贝
// 同一块 IOSurface 同时被 Metal 纹理与 CPU/CIImage 包装：GPU 写入后 CPU 直接读到，
// 全程无 memcpy——这就是 CVMetalTextureCache、Core Image 互操作的底层机制。
import CoreImage
import CoreVideo
import Metal
import Foundation

let dev = MTLCreateSystemDefaultDevice()!
let queue = dev.makeCommandQueue()!
print("=== IOSurface 跨框架零拷贝 ===")
print("Device:", dev.name)

let W = 256, H = 256

// ── 1. 创建 IOSurface 支撑的 CVPixelBuffer，再包装成 MTLTexture ──
// kCVPixelBufferIOSurfacePropertiesKey 正是让 CVPixelBuffer 有 IOSurface 支撑的开关，
// 有它才能被 Metal 绑定（缺了会报 -6660）
var pb: CVPixelBuffer?
let iosurfaceProps = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
let status = CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_32BGRA,
                                 [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                  kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
                                 &pb)
guard status == kCVReturnSuccess, let pixelBuffer = pb,
      let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { exit(1) }
let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                    width: W, height: H, mipmapped: false)
desc.usage = [.shaderWrite, .shaderRead]
desc.storageMode = .shared
let tex = dev.makeTexture(descriptor: desc, iosurface: surface, plane: 0)!
print("MTLTexture 包装自 IOSurface：\(tex.width)x\(tex.height)")

// ── 2. GPU compute 写入渐变 ──
let kernelSrc = """
#include <metal_stdlib>
using namespace metal;
kernel void gradient(texture2d<float, access::write> out [[texture(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    float2 uv = float2(gid) / float2(out.get_width() - 1, out.get_height() - 1);
    out.write(float4(uv.x, uv.y, 0.5, 1.0), gid);
}
"""
let lib = try! dev.makeLibrary(source: kernelSrc, options: nil)
let pso = try! dev.makeComputePipelineState(function: lib.makeFunction(name: "gradient")!)
guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { exit(1) }
enc.setComputePipelineState(pso)
enc.setTexture(tex, index: 0)
enc.dispatchThreads(MTLSize(width: W, height: H, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
enc.endEncoding(); cb.commit(); cb.waitUntilCompleted()

// ── 3. CPU 直接从同一块 IOSurface 读回（零拷贝验证）──
CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
var errCount = 0
let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
for y in Swift.stride(from: 0, to: H, by: 16) {
    for x in Swift.stride(from: 0, to: W, by: 16) {
        // BGRA 内存布局：p[0]=B(0.5→128) p[1]=G p[2]=R
        let p = CVPixelBufferGetBaseAddress(pixelBuffer)!.advanced(by: y * bytesPerRow + x * 4)
            .assumingMemoryBound(to: UInt8.self)
        let expectR = UInt8(Double(x) / Double(W - 1) * 255)
        let expectG = UInt8(Double(y) / Double(H - 1) * 255)
        if abs(Int(p[0]) - 128) > 2 || abs(Int(p[1]) - Int(expectG)) > 2
            || abs(Int(p[2]) - Int(expectR)) > 2 { errCount += 1 }
    }
}
CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
print(errCount == 0 ? "✅ CPU 读回与 GPU 写入一致（零拷贝共享成立）"
                    : "❌ \(errCount) 个采样点不一致")

// ── 4. 同一块 IOSurface 再包成 CIImage，走 Core Image 渲染 ──
let ciImg = CIImage(mtlTexture: tex, options: nil)!
let ciCtx = CIContext(mtlDevice: dev)
var outPx = [UInt8](repeating: 0, count: W * H * 4)
// 纹理值按线性 RGB 回读，避免 sRGB 编码改变数值；CIImage(mtlTexture:) 会垂直翻转，属 Core Image 约定
ciCtx.render(ciImg, toBitmap: &outPx, rowBytes: W * 4,
             bounds: ciImg.extent, format: .RGBA8,
             colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
var blueCount = 0
for i in stride(from: 0, to: outPx.count, by: 4) {
    if abs(Int(outPx[i + 2]) - 128) <= 2 && outPx[i + 3] == 255 { blueCount += 1 }
}
print("Core Image 回读蓝色通道=128 的比例: \(Double(blueCount) / Double(W * H) * 100)%")
print(blueCount > W * H * 9 / 10 ? "✅ 同一块 IOSurface 无缝进入 Core Image 管线" : "❌ Core Image 回读异常")
print("\n提示: CVMetalTextureCache 底层正是 IOSurface——这就是相机帧免 memcpy 进 Metal 的原因。")
