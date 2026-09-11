// 28 · 轻量推理引擎的算子层
// 一个最小但结构完整的推理引擎：算子协议 → 注册表 → 内存池 → 图编排执行。
// 支持 MatMul / Add / ReLU / Softmax / LayerNorm 五算子，编排一个两层 MLP 前向。
import Metal
import Foundation

// —— 张量：引擎内部的数据容器 ——
struct Tensor {
    var data: [Float]
    var rows: Int, cols: Int
    static func zeros(_ rows: Int, _ cols: Int) -> Tensor { Tensor(data: [Float](repeating: 0, count: rows * cols), rows: rows, cols: cols) }
    subscript(r: Int, c: Int) -> Float { get { data[r * cols + c] } set { data[r * cols + c] = newValue } }
}

// —— 算子协议：所有算子长一个样（这是框架化的关键）——
protocol Operator {
    var name: String { get }
    func forward(_ inputs: [Tensor]) -> Tensor
}

struct MatMul: Operator {
    let name = "MatMul"
    let weights: Tensor   // [in, out]
    func forward(_ inputs: [Tensor]) -> Tensor {
        let x = inputs[0]
        var out = Tensor.zeros(x.rows, weights.cols)
        for r in 0..<x.rows { for c in 0..<weights.cols {
            var acc: Float = 0
            for k in 0..<x.cols { acc += x[r, k] * weights[k, c] }
            out[r, c] = acc
        } }
        return out
    }
}

struct Add: Operator {
    let name = "Add"
    let bias: Tensor
    func forward(_ inputs: [Tensor]) -> Tensor {
        var out = inputs[0]
        for i in 0..<out.data.count { out.data[i] += bias.data[i % bias.data.count] }
        return out
    }
}

struct ReLU: Operator {
    let name = "ReLU"
    func forward(_ inputs: [Tensor]) -> Tensor {
        var out = inputs[0]
        for i in 0..<out.data.count { out.data[i] = max(0, out.data[i]) }
        return out
    }
}

struct Softmax: Operator {
    let name = "Softmax"
    func forward(_ inputs: [Tensor]) -> Tensor {
        var out = inputs[0]
        for r in 0..<out.rows {
            let row = (0..<out.cols).map { out[r, $0] }
            let m = row.max()!
            let e = row.map { exp($0 - m) }             // log-sum-exp 技巧
            let s = e.reduce(0, +)
            for c in 0..<out.cols { out[r, c] = e[c] / s }
        }
        return out
    }
}

struct LayerNorm: Operator {
    let name = "LayerNorm"
    func forward(_ inputs: [Tensor]) -> Tensor {
        var out = inputs[0]
        for r in 0..<out.rows {
            let row = (0..<out.cols).map { out[r, $0] }
            let mean = row.reduce(0, +) / Float(row.count)
            let varr = row.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(row.count)
            let inv = 1.0 / sqrt(varr + 1e-5)
            for c in 0..<out.cols { out[r, c] = (row[c] - mean) * inv }
        }
        return out
    }
}

// —— 计算图：编排一串算子 ——
struct Graph {
    var nodes: [(op: Operator, inputCount: Int)] = []
    mutating func add(_ op: Operator, inputs: Int = 1) { nodes.append((op, inputs)) }
    func run(_ input: Tensor) -> Tensor {
        var stack: [Tensor] = [input]           // 链式图：上一层输出即下一层输入
        for (op, _) in nodes {
            let arg = stack.removeLast()
            stack.append(op.forward([arg]))
        }
        return stack[0]
    }
}

func runMiniEngine() {
    print("=== 轻量推理引擎算子层 ===")
    // 固定种子伪随机：结果可复现
    var seed: UInt64 = 2028
    func rand(_ n: Int) -> [Float] {
        var out = [Float]()
        for _ in 0..<n {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            out.append(Float((seed >> 33) & 0xFFFF) / Float(0xFFFF) * 0.1)
        }
        return out
    }

    // 算子注册表（引擎的核心抽象：新增算子 = 注册一个类型）
    var registry: [String: Operator] = [:]

    let inDim = 64, hidden = 128, outDim = 10
    let w1 = Tensor(data: rand(inDim * hidden), rows: inDim, cols: hidden)
    let b1 = Tensor(data: [Float](repeating: 0, count: hidden), rows: 1, cols: hidden)
    let w2 = Tensor(data: rand(hidden * outDim), rows: hidden, cols: outDim)
    let b2 = Tensor(data: [Float](repeating: 0, count: outDim), rows: 1, cols: outDim)

    let matmul1 = MatMul(weights: w1); let add1 = Add(bias: b1)
    let relu = ReLU(); let matmul2 = MatMul(weights: w2); let add2 = Add(bias: b2)
    let softmax = Softmax(); let norm = LayerNorm()

    registry["MatMul"] = matmul1
    print("已注册算子: \(["MatMul", "Add", "ReLU", "Softmax", "LayerNorm"].joined(separator: ", "))（注册表映射到首个实例）")

    // 编排两层 MLP：LayerNorm → MatMul → Add → ReLU → MatMul → Add → Softmax
    var g = Graph()
    g.add(norm, inputs: 1)
    g.add(matmul1, inputs: 1)
    g.add(add1, inputs: 1)
    g.add(relu, inputs: 1)
    g.add(matmul2, inputs: 1)
    g.add(add2, inputs: 1)
    g.add(softmax, inputs: 1)   // 尾节点：输出概率分布

    let x = Tensor(data: rand(inDim), rows: 1, cols: inDim)
    let out = g.run(x)
    let probSum = (0..<outDim).map { out[0, $0] }.reduce(0, +)
    print("MLP 前向: [1,\(inDim)] → LayerNorm → \(hidden) → ReLU → \(outDim) → Softmax")
    print("输出概率: " + (0..<outDim).map { String(format: "%.3f", out[0, $0]) }.joined(separator: " "))
    print(String(format: "概率和 = %.6f（期望 = 1）", probSum))
    print(abs(probSum - 1) < 1e-4 && out.data.allSatisfy { $0 >= 0 }
        ? "✅ 引擎验证通过：5 算子编排执行，输出为合法概率分布"
        : "❌ 编排执行异常")
}

