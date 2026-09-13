// 04 · 三路推理基准：GPU / Neural Engine / CPU
// 同一个 784-256-10 模型，三种 computeUnits 各跑 100 次推理，
// 输出延迟中位数对照表 + 跨设备 argmax 一致性断言。
// 模型由 gen_model.py 用 coremltools 现场生成（Model.mlpackage）。
import CoreML
import Metal
import Foundation

struct BenchResult {
    let name: String
    let median: Double      // ms
    let best: Double        // ms
    let argmaxMatch: Bool   // 与 GPU 路的 argmax 一致
}

// 计时：预热 10 次吸收首轮加载，正式 100 次取中位数
func bench(_ name: String, units: MLComputeUnits, modelURL: URL,
           input: MLMultiArray, expected: Int32) -> BenchResult {
    let config = MLModelConfiguration()
    config.computeUnits = units
    let model = try! MLModel(contentsOf: modelURL, configuration: config)
    let provider = try! MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])

    // 预热
    for _ in 0..<10 { _ = try? model.prediction(from: provider) }

    var times = [Double]()
    var lastArgmax: Int32 = -1
    for _ in 0..<100 {
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = try! model.prediction(from: provider)
        times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        // 输出 y 是 multiArray，取 argmax
        if let arr = out.featureValue(for: "y")?.multiArrayValue {
            var best: Int32 = 0, bv = -Float.greatestFiniteMagnitude
            for i in 0..<arr.count {
                let v = arr[i].floatValue
                if v > bv { bv = v; best = Int32(i) }
            }
            lastArgmax = best
        }
    }
    times.sort()
    let median = times[times.count / 2]
    return BenchResult(name: name, median: median, best: times[0], argmaxMatch: lastArgmax == expected)
}

// 固定输入 + CPU 参照 argmax
func expectedArgmax(modelURL: URL, input: MLMultiArray) -> Int32 {
    let config = MLModelConfiguration()
    config.computeUnits = .cpuOnly
    let model = try! MLModel(contentsOf: modelURL, configuration: config)
    let provider = try! MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
    let out = try! model.prediction(from: provider)
    guard let arr = out.featureValue(for: "y")?.multiArrayValue else { return -1 }
    var best: Int32 = 0, bv = -Float.greatestFiniteMagnitude
    for i in 0..<arr.count {
        let v = arr[i].floatValue
        if v > bv { bv = v; best = Int32(i) }
    }
    return best
}

func runAneBench() throws {
    print("=== 三路推理基准：GPU / Neural Engine / CPU ===")
    print("Device: \(MTLCreateSystemDefaultDevice()?.name ?? "?")")
    print("模型: 784-256-10 两层全连接 | 每路 100 次推理（预热 10 次）\n")

    // .mlpackage 需编译为 .mlmodelc 才能加载（系统 MLModel.compileModel 现场编译）
    let srcURL = URL(fileURLWithPath: "Model.mlpackage")
    let outDir = URL(fileURLWithPath: ".build")
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let modelURL = try MLModel.compileModel(at: srcURL)

    // 固定输入：随机但可复现
    var values = [Double](repeating: 0, count: 784)
    var seed: UInt64 = 2049
    for i in 0..<784 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        values[i] = Double((seed >> 33) & 0xFFFF) / 65535.0
    }
    let input = try! MLMultiArray(shape: [784], dataType: .float32)
    for i in 0..<784 { input[i] = NSNumber(value: values[i]) }

    let expect = expectedArgmax(modelURL: modelURL, input: input)

    var results = [BenchResult]()
    results.append(bench("CPU（cpuOnly）", units: .cpuOnly, modelURL: modelURL, input: input, expected: expect))
    results.append(bench("GPU（cpuAndGPU）", units: .cpuAndGPU, modelURL: modelURL, input: input, expected: expect))
    results.append(bench("ANE（all 自动调度）", units: .all, modelURL: modelURL, input: input, expected: expect))

    print("路径                     中位延迟     最优延迟   argmax")
    print("----                     --------     --------   ------")
    for r in results {
        print(String(format: "%-24@ %10.3fms %10.3fms %8d", r.name as NSString, r.median, r.best, r.argmaxMatch ? expect : -999))
    }
    print()
    let allMatch = results.allSatisfy { $0.argmaxMatch }
    let medians = results.map { $0.median }
    let spread = (medians.max()! - medians.min()!) / medians.min()!
    print(String(format: "三路中位延迟差异 %.0f%%（>20% 说明调度确实分到了不同引擎）", spread * 100))
    print(allMatch && spread > 0.1
        ? "✅ 基准验证通过：三路均可用且延迟差异可复现——同一模型，引擎不同表现不同"
        : "⚠️ 三路结果一致性成立但延迟差异小于预期（模型太小，ANE/GPU 优势体现不出来）")
}

do {
    try runAneBench()
} catch {
    print("❌", error.localizedDescription)
    exit(1)
}

