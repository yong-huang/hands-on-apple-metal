// 29 · 自定义图像算子：MPS 管线 + 自研滤镜内核
// MPS 没有的效果就要自己写 kernel。"油画感"滤镜 = 色彩posterize（量化）+ 轻微模糊：
// 先用 MPSImageGaussianBlur 轻模糊去噪，再接自定义 posterize 内核量化色彩。
// 本实验验证：自定义内核可以无缝插进 MPS 滤镜流水线。
import Metal
import MetalPerformanceShaders
import Foundation

let filterSource = """
#include <metal_stdlib>
using namespace metal;
// Posterize：每通道量化到 LEVELS 级 → 色块感（油画/赛博朋克滤镜的基础件）
kernel void posterize(texture2d<float, access::read>  src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant uint& levels [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    uint W = src.get_width(), H = src.get_height();
    if (gid.x >= W || gid.y >= H) { return; }
    float4 c = src.read(gid);
    float step = 1.0 / float(levels);
    float3 q = floor(c.rgb / step) * step + step * 0.5;   // 量化到级中心
    dst.write(float4(q, c.a), gid);
}
"""

func makeTex(_ device: MTLDevice, _ w: Int, _ h: Int, px: [UInt8]) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
    let t = device.makeTexture(descriptor: d)!
    if px.count > 0 { t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4) }
    return t
}

func runCustomFilter() {
    print("=== 自定义图像算子（MPS + 自研内核流水线）===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let (w, h) = (256, 256)
    // 测试图：平滑渐变（posterize 后应只剩 LEVELS 种灰度）
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        let v = UInt8((x + y) * 255 / (w + h - 2))
        px[i] = v; px[i+1] = v; px[i+2] = v; px[i+3] = 255
    } }
    let src = makeTex(device, w, h, px: px)
    let mid = makeTex(device, w, h, px: [])
    let dst = makeTex(device, w, h, px: [])

    // —— 流水线：MPS 模糊（去噪）→ 自定义 posterize ——
    let blur = MPSImageGaussianBlur(device: device, sigma: 1.5)
    let library = try! device.makeLibrary(source: filterSource, options: nil)
    let pso = try! device.makeComputePipelineState(function: library.makeFunction(name: "posterize")!)
    var levels: UInt32 = 4

    guard let cb = queue.makeCommandBuffer() else { exit(1) }
    blur.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: mid)
    if let enc = cb.makeComputeCommandEncoder() {
        enc.setComputePipelineState(pso)
        enc.setTexture(mid, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&levels, length: 4, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
    }
    cb.commit(); cb.waitUntilCompleted()

    // 验证：输出中出现的不同灰度值 ≤ LEVELS（量化生效）
    var out = [UInt8](repeating: 0, count: w * h * 4)
    dst.getBytes(&out, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    var seen = Set<UInt8>()
    for i in stride(from: 0, to: out.count, by: 4) { seen.insert(out[i]) }
    print("输入灰度级: 256 → 输出灰度级: \(seen.sorted())")
    print(seen.count <= 4
        ? "✅ 自定义滤镜验证通过：posterize 量化到 ≤\(levels) 级，并与 MPS 模糊无缝串联"
        : "❌ 灰度级数异常")
    print("思路：滤镜开发 = MPS 现成算子做前处理 + 自定义内核做差异化后处理")
}
