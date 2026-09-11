// 10 · 阈值二值化：MPSImageThresholdToZero
// 最简单的"非参数算子"：一个阈值参数决定一切。练习参数化验证的思路。
import Metal
import MetalPerformanceShaders
import Foundation

func gradientTexture(_ device: MTLDevice, w: Int, h: Int) -> MTLTexture {
    // 0→255 的水平灰度渐变：给定阈值 T，恰有 (1-T/255) 比例的像素保留
    var px = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        let v = UInt8(x * 255 / (w - 1))
        px[i] = v; px[i+1] = v; px[i+2] = v; px[i+3] = 255
    } }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
    let t = device.makeTexture(descriptor: d)!
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
    return t
}

func runThreshold() {
    print("=== MPS 10 · 阈值二值化 ===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let (w, h) = (256, 64)
    let src = gradientTexture(device, w: w, h: h)

    for tNorm: Float in [0.25, 0.5, 0.75] {
        let dst = gradientTexture(device, w: w, h: h)
        let threshold = MPSImageThresholdToZero(device: device, thresholdValue: tNorm, linearGrayColorTransform: nil)
        guard let cb = queue.makeCommandBuffer() else { exit(1) }
        threshold.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: dst)
        cb.commit(); cb.waitUntilCompleted()

        // 验证：保留的像素值应 ≥ T，清零的应 = 0；统计保留列数与理论值比对
        var px = [UInt8](repeating: 0, count: w * h * 4)
        dst.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        var keptCols = 0, zeroOk = true
        for x in 0..<w {
            let v = Int(px[(32 * w + x) * 4])
            if v > 0 {
                keptCols += 1
                if Float(v) < tNorm * 255 - 1 { zeroOk = false }   // 保留值必须 ≥ 阈值
            }
        }
        let expectCols = w - Int((tNorm * 255).rounded(.up))   // v >= 阈值才保留
        let ok = keptCols == expectCols && zeroOk
        print("T=\(tNorm): 保留 \(keptCols)/\(w) 列（理论 \(expectCols)），低于阈值的像素全部清零 \(zeroOk ? "✓" : "✗") → \(ok ? "✅" : "❌")")
    }
    print("阈值算子的通用形态：output = input > T ? input : 0（硬截断，无过渡）")
}
