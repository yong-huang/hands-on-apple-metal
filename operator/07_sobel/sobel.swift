// 07 · Sobel 边缘检测：MPSImageSobel
// MPS 的价值：一个滤镜 = 苹果调优过的内核族。你不写 kernel，只描述"要什么"。
import Metal
import MetalPerformanceShaders
import Foundation

func makeTestTexture(_ device: MTLDevice, w: Int, h: Int) -> MTLTexture {
    // 程序内生成测试图：灰底 + 白色方块（有明确边缘可供检测）
    var px = [UInt8](repeating: 64, count: w * h * 4)
    for y in h / 4..<h * 3 / 4 {
        for x in w / 4..<w * 3 / 4 {
            let i = (y * w + x) * 4
            px[i] = 255; px[i+1] = 255; px[i+2] = 255; px[i+3] = 255
        }
    }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    d.storageMode = .shared
    let t = device.makeTexture(descriptor: d)!
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
    return t
}

func runSobel() {
    print("=== MPS 07 · Sobel 边缘检测 ===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let (w, h) = (256, 256)
    let src = makeTestTexture(device, w: w, h: h)
    let dst = makeTestTexture(device, w: w, h: h)

    // MPS 三步：建滤镜 → 编码到命令缓冲 → 提交。梯度/权重全由 MPS 管理
    let sobel = MPSImageSobel(device: device)
    guard let cb = queue.makeCommandBuffer() else { exit(1) }
    sobel.encode(commandBuffer: cb, sourceTexture: src, destinationTexture: dst)
    cb.commit(); cb.waitUntilCompleted()

    // 验证：边缘处（方块边框上）响应应远大于平坦区中心
    func sampleLuma(_ x: Int, _ y: Int) -> Float {
        var px = [UInt8](repeating: 0, count: 4)
        dst.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return Float(px[0])
    }
    let edge = max(sampleLuma(w / 4, h / 2), sampleLuma(w / 2, h / 4))    // 竖边与横边
    let flat = sampleLuma(w / 2, h / 2)                                    // 方块中心（平坦）
    print(String(format: "边缘响应: %.0f | 平坦区响应: %.0f", edge, flat))
    print(edge > flat * 2 ? "✅ Sobel 验证通过：边缘位置响应显著更强" : "❌ 边缘响应异常")
    print("Sobel 算子本质: 3×3 卷积核分别在 x/y 方向求差分 → 梯度模长即边缘强度")
}
