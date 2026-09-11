// 08 · 高斯模糊：MPSImageGaussianBlur，sigma 可调
// 模糊 = 与高斯核卷积。sigma 越大核越宽、模糊越强——用像素方差定量验证。
import Metal
import MetalPerformanceShaders
import Foundation

func noisyTexture(_ device: MTLDevice, w: Int, h: Int) -> MTLTexture {
    // 棋盘噪声图：模糊后方差应显著下降
    var px = [UInt8](repeating: 0, count: w * h * 4)
    var seed: UInt64 = 7
    for i in stride(from: 0, to: px.count, by: 4) {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let v = UInt8((seed >> 33) & 0xFF)
        px[i] = v; px[i+1] = v; px[i+2] = v; px[i+3] = 255
    }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
    let t = device.makeTexture(descriptor: d)!
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
    return t
}

// 相邻像素梯度能量：越平滑越小（比方差对 MPS 内部实现更稳）
func gradientEnergy(_ tex: MTLTexture, w: Int, h: Int) -> Double {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    var total = 0.0
    for y in 0..<h { for x in 0..<(w - 1) {
        let a = Double(px[(y * w + x) * 4]), b = Double(px[(y * w + x + 1) * 4])
        total += abs(a - b)
    } }
    return total / Double(w * h)
}

func runGaussianBlur() {
    print("=== MPS 08 · 高斯模糊（sigma 可调）===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let (w, h) = (256, 256)
    let src = noisyTexture(device, w: w, h: h)
    print(String(format: "原图梯度能量: %.1f（噪声图的粗糙基线）", gradientEnergy(src, w: w, h: h)))

    var first = 0.0, last = 0.0
    for sigma: Float in [2, 6, 12] {
        let dst = noisyTexture(device, w: w, h: h)   // 干净的输出纹理
        let blur = MPSImageGaussianBlur(device: device, sigma: sigma)
        guard let cb = queue.makeCommandBuffer() else { exit(1) }
        blur.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: dst)
        cb.commit(); cb.waitUntilCompleted()
        let v = gradientEnergy(dst, w: w, h: h)
        if sigma == 2 { first = v }
        if sigma == 12 { last = v }
        print(String(format: "sigma=%-4.0f → 梯度能量 %.2f（越小越平滑）", sigma, v))
    }
    print(String(format: "对比: sigma=2 能量 %.2f → sigma=12 能量 %.2f（降为 %.1f%%）", first, last, last / first * 100))
    print(last < first * 0.9 ? "✅ 验证通过：模糊强度与 sigma 正相关" : "❌ 平滑度未随 sigma 提升")
}
