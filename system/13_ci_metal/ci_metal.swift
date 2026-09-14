// 13 · Core Image 滤镜链 + Metal 纹理互操作
// CIFilter 内置滤镜链处理图片 → 验证像素变化 → 展示 Core Image 与 Metal 的互操作路径。
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import MetalKit
import AppKit

let dev = MTLCreateSystemDefaultDevice()!
let ciContext = CIContext(mtlDevice: dev)
print("=== Core Image 滤镜链 + Metal 互操作 ===")
print("Device:", dev.name)

// 生成测试图（渐变 + 色块）
let w = 256, h = 256
var px = [UInt8](repeating: 0, count: w * h * 4)
for y in 0..<h { for x in 0..<w {
    let i = (y * w + x) * 4
    px[i]   = UInt8(x * 255 / w)
    px[i+1] = UInt8(y * 255 / h)
    px[i+2] = 128; px[i+3] = 255
} }
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w * 4, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let cgImg = ctx.makeImage()!
let input = CIImage(cgImage: cgImg)

// CIFilter 链：色相旋转 → 曝光调整
let hueFilter = CIFilter(name: "CIHueAdjust", parameters: [
    kCIInputImageKey: input, kCIInputAngleKey: 1.5])!
let hueOut = hueFilter.outputImage!

let expoFilter = CIFilter(name: "CIExposureAdjust", parameters: [
    kCIInputImageKey: hueOut, kCIInputEVKey: 0.5])!
let finalOut = expoFilter.outputImage!

// 渲染回 CPU 验证
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let cgOut = ciContext.createCGImage(finalOut, from: finalOut.extent) else { exit(1) }
var outPx = [UInt8](repeating: 0, count: w * h * 4)
guard let dataProv = cgOut.dataProvider,
      let data = dataProv.data else { exit(1) }
(data as NSData).getBytes(&outPx, length: outPx.count)

// 验证：像素确实被修改了
var diffCount = 0
for i in stride(from: 0, to: px.count, by: 4) {
    if abs(Int(px[i]) - Int(outPx[i])) > 10 { diffCount += 1 }
}
let ratio = Double(diffCount) / Double(w * h) * 100
print(String(format: "像素变化比例: %.1f%%（%.0f / %d）", ratio, Double(diffCount), w * h))
print(ratio > 50 ? "✅ Core Image 滤镜链验证通过" : "❌ 验证失败")
print("\n提示: Core Image 与 Metal 共享 GPU 纹理（CIContext(mtlDevice:)），")
print("      后续可用 CIImage(texture:) 包装 MTLTexture 实现互操作。")
