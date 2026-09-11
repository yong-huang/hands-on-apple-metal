// 09 · Bloom 辉光：三个 MPS 滤镜的组合拳
// Bloom = 提取高光(阈值) → 晕开(模糊) → 叠回原图(加法)。
// 组合 MPS 滤镜是"算子流水线"思维的最小案例。
import Metal
import MetalPerformanceShaders
import Foundation

func sceneTexture(_ device: MTLDevice, w: Int, h: Int) -> MTLTexture {
    // 暗背景 + 两个高亮圆点（Bloom 后圆点周围应出现光晕）
    var px = [UInt8](repeating: 10, count: w * h * 4)
    func dot(_ cx: Int, _ cy: Int, _ r: Int, _ v: UInt8) {
        for y in max(0, cy-r)...min(h-1, cy+r) {
            for x in max(0, cx-r)...min(w-1, cx+r) {
                if (x-cx)*(x-cx) + (y-cy)*(y-cy) <= r*r {
                    let i = (y*w+x)*4; px[i] = v; px[i+1] = v; px[i+2] = v; px[i+3] = 255
                }
            }
        }
    }
    dot(w/3, h/2, 12, 255)     // 高亮点
    dot(2*w/3, h/2, 12, 60)    // 暗点（不应产生辉光）
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .shared
    let t = device.makeTexture(descriptor: d)!
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
    return t
}

func lumaAt(_ tex: MTLTexture, _ x: Int, _ y: Int, _ w: Int) -> Int {
    var px = [UInt8](repeating: 0, count: 4)
    tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return Int(px[0])
}

func runBloom() {
    print("=== MPS 09 · Bloom 辉光（阈值 + 模糊 + 叠加）===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let (w, h) = (256, 256)
    let scene = sceneTexture(device, w: w, h: h)
    let bright = sceneTexture(device, w: w, h: h)   // 阈值输出
    let blurred = sceneTexture(device, w: w, h: h)  // 模糊输出
    let final = sceneTexture(device, w: w, h: h)    // 叠加输出

    guard let cb = queue.makeCommandBuffer() else { exit(1) }
    // 第一拳：提取高光（低于 0.3 的清零）
    let threshold = MPSImageThresholdToZero(device: device, thresholdValue: 0.3, linearGrayColorTransform: nil)
    threshold.encode(commandBuffer: cb, sourceTexture: scene, destinationTexture: bright)
    // 第二拳：把高光晕开
    let blur = MPSImageGaussianBlur(device: device, sigma: 8)
    blur.encode(commandBuffer: cb, sourceTexture: bright, destinationTexture: blurred)
    // 第三拳：晕光叠回原图
    let add = MPSImageAdd(device: device)
    add.encode(commandBuffer: cb, primaryTexture: scene, secondaryTexture: blurred, destinationTexture: final)
    cb.commit(); cb.waitUntilCompleted()

    // 验证：高亮点的"光晕环"（点外 5px 处）应变亮；暗点周围不应变亮
    let haloBright = lumaAt(final, w/3 + 17, h/2, w)          // 亮点光晕环
    let haloDark = lumaAt(final, 2*w/3 + 17, h/2, w)          // 暗点同位置
    let before = lumaAt(scene, w/3 + 17, h/2, w)
    print("原图光晕环亮度: \(before) → Bloom 后: \(haloBright)（亮点周围）")
    print("暗点同位置: \(haloDark)（应仍接近背景 10）")
    print(haloBright > before + 20 && haloDark < 40
        ? "✅ Bloom 验证通过：只有高光产生辉光"
        : "❌ 辉光分布异常")
}
