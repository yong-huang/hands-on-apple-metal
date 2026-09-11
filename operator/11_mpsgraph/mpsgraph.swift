// 11 · MPSGraph：把算子组合成"计算图"
// MPSGraph 是 MPS 的图执行层（TensorFlow-Metal 的底层）：
// 占位符 → 图算子 → 编译执行。本实验构建 (x−0.5)×2 → clamp(0,1) 的最小图，
// 用渐变数据喂入并回读验证——体会"声明式计算图"与"直接编码滤镜"的差别。
import Metal
import MetalPerformanceShaders
import MetalPerformanceShadersGraph
import Foundation

func runMpsgraph() {
    print("=== MPS 11 · MPSGraph 计算图 ===")
    guard let device = MTLCreateSystemDefaultDevice(),
          let queue = device.makeCommandQueue() else { print("❌ 无 Metal"); exit(1) }
    print("Device: \(device.name)")

    let (w, h) = (128, 128)
    // 输入数据：水平渐变（NHWC 布局 [1,h,w,1]）
    var px = [Float](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w { px[y * w + x] = Float(x) / Float(w - 1) } }

    // —— 建图：占位符 → 算子节点 → 输出 ——
    let graph = MPSGraph()
    let shape: [NSNumber] = [1, NSNumber(value: h), NSNumber(value: w), 1]
    let input = graph.placeholder(shape: shape, dataType: .float32, name: "input")
    let two = graph.constant(2.0, dataType: .float32)
    let half = graph.constant(0.5, dataType: .float32)
    let scaled = graph.multiplication(graph.subtraction(input, half, name: "sub"), two, name: "scale")
    let output = graph.clamp(scaled, min: graph.constant(0.0, dataType: .float32),
                                  max: graph.constant(1.0, dataType: .float32), name: "output")
    print("图结构: input → (x−0.5)×2 → clamp(0,1) → output")

    // —— 执行：CPU 数据 → 图 → 同步回 CPU（run 会阻塞到完成）——
    let graphDevice = MPSGraphDevice(mtlDevice: device)
    let inData = Data(bytes: px, count: w * h * 4) as NSData
    let feed = MPSGraphTensorData(device: graphDevice, data: inData as Data, shape: shape, dataType: .float32)
    let results = graph.run(feeds: [input: feed], targetTensors: [output], targetOperations: nil)
    let outArray = results[output]!.mpsndarray()

    // 回读验证：左端→0，中点→0（(0.5−0.5)×2），右端→1
    var got = [Float](repeating: -1, count: w * h)
    got.withUnsafeMutableBytes { ptr in
        var strides: [Int] = [w * h * 4, w * 4, 4, 4]
        strides.withUnsafeMutableBufferPointer { sbp in
            outArray.readBytes(ptr.baseAddress!, strideBytes: sbp.baseAddress!)
        }
    }
    // 全量统计：输出值域应覆盖 [0, ~0.98]（左端截到 0，右端 ≈0.98 未触顶）
    let mn = got.min() ?? -1, mx = got.max() ?? -1
    print(String(format: "输出值域: min=%.3f max=%.3f（期望 min≈0，max≈0.98，渐变经拉伸后触底不封顶）", mn, mx))
    print(abs(mn) < 0.02 && abs(mx - 0.984) < 0.03
        ? "✅ MPSGraph 计算图验证通过：3 个算子节点按图序正确执行"
        : "❌ 数值与期望不符")
}
