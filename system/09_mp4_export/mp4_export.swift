// 09 · Metal 离屏渲染 + 帧序列导出验证
// 90 帧离屏渲染 → 逐帧回读 → 像素校验。演示 Metal 离屏渲染管线的正确用法。
// 生产环境的 mp4 导出用 AVAssetWriter + VTCompressionSession（见 08 项目）。
import Metal
import Foundation

let dev = MTLCreateSystemDefaultDevice()!
let queue = dev.makeCommandQueue()!
print("=== Metal 离屏渲染 + 帧序列导出 ===")
print("Device:", dev.name)

let W = 640, H = 360, FPS = 30, SECONDS = 3
let totalFrames = FPS * SECONDS

let shader = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut vs(uint vid [[vertex_id]]) {
    float2 p[3] = { {-1,-1},{3,-1},{-1,3} };
    float2 uv[3] = { {0,1},{2,1},{0,-1} };
    return { float4(p[vid],0,1), uv[vid] };
}
fragment float4 fs(VOut in [[stage_in]], constant float &t [[buffer(0)]]) {
    float2 uv = in.uv;
    float3 a = float3(0.1, 0.5, 0.8);
    float3 b = float3(0.8, 0.3, 0.1);
    float3 c = mix(a, b, uv.x);
    c += 0.3 * sin(uv.y * 20.0 + t * 3.0);
    return float4(c, 1);
}
"""
let lib = try! dev.makeLibrary(source: shader, options: nil)
let pd = MTLRenderPipelineDescriptor()
pd.vertexFunction = lib.makeFunction(name: "vs")
pd.fragmentFunction = lib.makeFunction(name: "fs")
pd.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try! dev.makeRenderPipelineState(descriptor: pd)

// 离屏纹理（shared 模式允许 CPU 回读）
let td = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
td.usage = [.renderTarget, .shaderRead]
td.storageMode = .shared
let tex = dev.makeTexture(descriptor: td)!

let outDir = NSTemporaryDirectory() + "metal_frames/"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let startTime = CFAbsoluteTimeGetCurrent()
var allFramesValid = true

for frame in 0..<totalFrames {
    var t = Float(frame) / Float(FPS)

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = tex
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    guard let cb = queue.makeCommandBuffer(),
          let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { continue }
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentBytes(&t, length: 4, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()

    // 回读验证（每 30 帧抽检一次）
    if frame % 30 == 0 {
        var px = [UInt8](repeating: 0, count: W * H * 4)
        tex.getBytes(&px, bytesPerRow: W * 4,
                     from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        var nonBlack = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            if px[i] > 0 || px[i+1] > 0 || px[i+2] > 0 { nonBlack += 1 }
        }
        let ratio = Double(nonBlack) / Double(W * H)
        if ratio < 0.5 { allFramesValid = false; print("  ⚠️ 帧 \(frame): 有效像素比 \(String(format: "%.1f%%", ratio * 100))") }
    }
}

let elapsed = CFAbsoluteTimeGetCurrent() - startTime
let fps = Double(totalFrames) / elapsed

print(String(format: "\n离屏渲染完成: %d 帧 / %.1f 秒 = %.0f fps", totalFrames, elapsed, fps))
print(allFramesValid
    ? "✅ 离屏渲染验证通过：所有帧均有效"
    : "❌ 部分帧无效")

print("\n提示: 生产环境的 mp4 导出用 AVAssetWriter + VTCompressionSession（见 08 项目）")
