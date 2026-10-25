import Cocoa
import Metal
import MetalKit
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// 每帧/每帧导出下发给片元着色器的参数。SIMD4 打包避免 Swift/MSL 对齐差异：
// u0 = (seed, time(动画预留，导出固定 0), scale(噪声缩放), warpStrength(扭曲强度))
// u1 = (resX, resY, 0, 0)  渲染目标分辨率，用于把像素坐标归一到短边 [-0.5, 0.5]
struct WarpUniforms {
    var u0: SIMD4<Float>
    var u1: SIMD4<Float>
}

// 值噪声 + fbm + 两层域扭曲的片元着色器：把平直的 uv 场"揉"出大理石纹/极光纹
let warpShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct WarpUniforms {
    float4 u0;   // seed, time, scale, warpStrength
    float4 u1;   // resX, resY, 0, 0
};

// 哈希：二维格点 → 0~1 随机数（含 seed，换 seed 即换一张图）
float hash(float2 p, float seed) {
    float3 p3 = fract(float3(p.x, p.y, seed) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// 值噪声：格点随机值的双线性平滑插值
float valueNoise(float2 p, float seed) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);   // smoothstep 缓动，消除双线性折痕
    float a = hash(i, seed);
    float b = hash(i + float2(1.0, 0.0), seed);
    float c = hash(i + float2(0.0, 1.0), seed);
    float d = hash(i + float2(1.0, 1.0), seed);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// fbm：五个倍频程的噪声叠加，频率翻倍、振幅减半——自然纹理的基本功
float fbm(float2 p, float seed) {
    float v = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        v += amp * valueNoise(p, seed + float(i) * 17.0);
        p = p * 2.0 + float2(11.3, 7.7);
        amp *= 0.5;
    }
    return v;
}

fragment float4 fragment_main(
    float4 fragCoord [[position]],
    constant WarpUniforms &u [[buffer(1)]]
) {
    float seed = u.u0.x;
    float scale = u.u0.z;
    float strength = u.u0.w;

    // 像素坐标 → 以画面中心为原点、短边归一到 [-0.5, 0.5]：横竖屏导出都不拉伸
    float2 uv = (fragCoord.xy - 0.5 * u.u1.xy) / min(u.u1.x, u.u1.y);
    float2 p = uv * scale;

    // 两层域扭曲：先用 fbm 场位移 p，再用扭曲后的 fbm 再位移一次——平直噪声被"揉"出流动纹理
    float2 q = float2(fbm(p, seed), fbm(p + float2(5.2, 1.3), seed));
    float2 r = float2(fbm(p + strength * q + float2(1.7, 9.2), seed),
                      fbm(p + strength * q + float2(8.3, 2.8), seed));
    float f = fbm(p + strength * r, seed);

    // 混合 q/r 分量上色：三层 fbm 各贡献一路颜色，形成大理石与极光交织的色带
    float3 col = mix(float3(0.10, 0.15, 0.30), float3(0.90, 0.85, 0.70), f);
    col = mix(col, float3(0.85, 0.45, 0.30), clamp(q.x * q.x, 0.0, 1.0) * 0.7);
    col = mix(col, float3(0.20, 0.55, 0.60), clamp(r.y * r.y, 0.0, 1.0) * 0.6);
    return float4(clamp(col, 0.0, 1.0), 1.0);
}
"""

let warpVertexSource = """
#include <metal_stdlib>
using namespace metal;

struct WarpVertexOut {
    float4 position [[position]];
};

vertex WarpVertexOut vertex_main(
    const device float2 *positions [[buffer(0)]],
    uint vid [[vertex_id]]
) {
    WarpVertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    return out;
}
"""

let warpQuad: [SIMD2<Float>] = [
    SIMD2(-1, -1), SIMD2(1, -1), SIMD2(-1, 1),
    SIMD2(-1, 1), SIMD2(1, -1), SIMD2(1, 1),
]

func makeWarpPipeline(device: MTLDevice, colorFormat: MTLPixelFormat) -> MTLRenderPipelineState {
    let library = try! device.makeLibrary(source: warpVertexSource + "\n" + warpShaderSource, options: nil)
    guard let vf = library.makeFunction(name: "vertex_main"),
          let ff = library.makeFunction(name: "fragment_main") else {
        fatalError("着色器函数缺失：vertex_main / fragment_main")
    }
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = vf
    desc.fragmentFunction = ff
    desc.colorAttachments[0].pixelFormat = colorFormat
    return try! device.makeRenderPipelineState(descriptor: desc)
}

// MARK: - 离屏导出（本实验无窗口模式：噪声图是静态的，导出即全部）

func exportWarpPNG(path: String, seed: Float, width: Int = 3840, height: Int = 2160,
                   scale: Float = 3.0, strength: Float = 3.5) {
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else {
        fatalError("本机不支持 Metal")
    }
    let pipeline = makeWarpPipeline(device: device, colorFormat: .rgba8Unorm)
    let vertexBuffer = device.makeBuffer(
        bytes: warpQuad,
        length: warpQuad.count * MemoryLayout<SIMD2<Float>>.stride,
        options: .storageModeShared
    )!

    let texDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
    texDesc.usage = [.renderTarget, .shaderRead]
    let texture = device.makeTexture(descriptor: texDesc)!

    let rpd = MTLRenderPassDescriptor()
    rpd.colorAttachments[0].texture = texture
    rpd.colorAttachments[0].loadAction = .clear
    rpd.colorAttachments[0].storeAction = .store
    rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rpd)!
    enc.setRenderPipelineState(pipeline)
    enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    var u = WarpUniforms(u0: SIMD4(seed, 0, scale, strength), u1: SIMD4(Float(width), Float(height), 0, 0))
    enc.setFragmentBytes(&u, length: MemoryLayout<WarpUniforms>.stride, index: 1)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: warpQuad.count)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()

    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let image = ctx.makeImage()!
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("PNG 写出失败：\(path)")
    }

    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    print("seed \(seed)  尺寸 \(width)×\(height)  噪声缩放 \(scale)  扭曲强度 \(strength)")
    print("导出 → \(path)")
    print("✅ PNG 已写出（\(size) 字节）")
}

func runWarp() {
    let args = CommandLine.arguments

    // export 模式：warp export out.png [seed] —— 4K 离屏导出
    if let i = args.firstIndex(of: "export"), args.count > i + 1 {
        let path = args[i + 1]
        let seed = args.count > i + 2 ? (Float(args[i + 2]) ?? 1.0) : 1.0
        exportWarpPNG(path: path, seed: seed)
        exit(0)
    }

    print("用法: warp export <out.png> [seed]（本实验为静态生成图，导出即全部；无窗口模式）")
    exit(2)
}
