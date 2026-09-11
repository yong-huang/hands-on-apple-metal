// 24 · 加载并渲染 3D 模型（OBJ）
// OBJ 是最朴素的模型格式：文本、逐行解析。本实验手写一个最小解析器
// （v / vn / f v//vn 三类行），把模型装进 Metal 缓冲，再用 11 的光照方程渲染。
import Cocoa
import Metal
import MetalKit
import simd

struct ModelVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    var color: SIMD4<Float>
}

struct ObjUniforms {
    var mvp: simd_float4x4
    var model: simd_float4x4
}

// MARK: - 最小 OBJ 解析器：只认 v / vn / f v//vn
enum ObjParser {
    static func parse(path: String) throws -> (vertices: [SIMD3<Float>], normals: [SIMD3<Float>], faces: [(v: [Int], n: [Int])]) {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var verts: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], faces: [(v: [Int], n: [Int])] = []
        for line in text.split(separator: "\n") {
            let t = line.split(separator: " ").map(String.init)
            switch t.first {
            case "v":
                verts.append(SIMD3(Float(t[1])!, Float(t[2])!, Float(t[3])!))
            case "vn":
                normals.append(SIMD3(Float(t[1])!, Float(t[2])!, Float(t[3])!))
            case "f":
                // "1//1 2//1 3//1" → 顶点索引 [0,1,2]、法线索引 [0,0,0]（OBJ 是 1-based）
                var vIdx: [Int] = [], nIdx: [Int] = []
                for corner in t.dropFirst() {
                    let pair = corner.split(separator: "/").map { Int($0)! - 1 }
                    vIdx.append(pair[0]); nIdx.append(pair.count > 1 ? pair[1] : 0)
                }
                faces.append((vIdx, nIdx))
            default:
                break   // 注释行(#)与其他标签一律忽略
            }
        }
        return (verts, normals, faces)
    }
}

class ObjModelViewController: NSViewController, MTKViewDelegate {

    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var depthState: MTLDepthStencilState!
    var vertexBuffer: MTLBuffer!
    var uniformBuffer: MTLBuffer!
    var triangleCount = 0
    var angle: Float = 0

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex {
        float3 position;
        float3 normal;
        float4 color;
    };
    struct Uniforms {
        float4x4 mvp;
        float4x4 model;
    };
    struct RasterizerData {
        float4 position [[position]];
        float3 normal;
        float4 color;
    };
    vertex RasterizerData vertex_main(
        device const Vertex *verts [[buffer(0)]],
        constant Uniforms &uni [[buffer(1)]],
        uint vid [[vertex_id]])
    {
        RasterizerData out;
        out.position = uni.mvp * float4(verts[vid].position, 1.0);
        out.normal = (uni.model * float4(verts[vid].normal, 0.0)).xyz;
        out.color = verts[vid].color;
        return out;
    }
    fragment float4 fragment_main(
        RasterizerData in [[stage_in]],
        constant float3 &lightDir [[buffer(0)]])
    {
        float diffuse = max(dot(normalize(in.normal), normalize(lightDir)), 0.0);
        return in.color * (0.25 + diffuse);
    }
    """

    func buildModelVertices() throws -> [ModelVertex] {
        // 演示脚本会把 cwd 设为实验目录；从可执行文件位置向上找做兜底
        let candidates = [
            FileManager.default.currentDirectoryPath + "/cube.obj",
            Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("../cube.obj").path,
        ]
        guard let objPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw NSError(domain: "ObjError", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 cube.obj"])
        }
        let obj = try ObjParser.parse(path: objPath)
        print("OBJ 解析: \(obj.vertices.count) 顶点 / \(obj.normals.count) 法线 / \(obj.faces.count) 个三角形面")
        // 展开索引：OBJ 是索引几何，Metal 这边直接展开成逐三角形顶点（教学从简）
        var out: [ModelVertex] = []
        let palette: [SIMD4<Float>] = [
            SIMD4(1.0, 0.45, 0.35, 1), SIMD4(0.35, 1.0, 0.55, 1), SIMD4(0.4, 0.65, 1.0, 1),
            SIMD4(1.0, 0.9, 0.35, 1), SIMD4(0.35, 1.0, 1.0, 1), SIMD4(0.9, 0.45, 1.0, 1),
        ]
        for (fi, face) in obj.faces.enumerated() {
            let color = palette[fi % palette.count]
            for k in 0..<3 {
                out.append(ModelVertex(
                    position: obj.vertices[face.v[k]],
                    normal: obj.normals[face.n[k]],
                    color: color))
            }
        }
        triangleCount = obj.faces.count
        return out
    }

    // 复用 10 的矩阵工具
    func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5), x = y / aspect
        let zz = -(far + near) / (far - near), w = -2 * far * near / (far - near)
        return simd_float4x4(columns: (
            SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
            SIMD4(0, 0, zz, -1), SIMD4(0, 0, w, 0)))
    }
    func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)
        return simd_float4x4(columns: (
            SIMD4(x.x, y.x, z.x, 0), SIMD4(x.y, y.y, z.y, 0),
            SIMD4(x.z, y.z, z.z, 0),
            SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
    }
    func rotationY(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0),
            SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }
    func rotationX(_ a: Float) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0),
            SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let v = MTKView(frame: view.bounds, device: MTLCreateSystemDefaultDevice())
        v.autoresizingMask = [.width, .height]
        view.addSubview(v)
        device = v.device
        commandQueue = device.makeCommandQueue()
        v.delegate = self
        v.clearColor = MTLClearColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)
        v.depthStencilPixelFormat = .depth16Unorm
        v.clearDepth = 1.0

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "vertex_main")
            desc.fragmentFunction = library.makeFunction(name: "fragment_main")
            desc.colorAttachments[0].pixelFormat = v.colorPixelFormat
            desc.depthAttachmentPixelFormat = .depth16Unorm
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = .less
            d.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: d)

            let verts = try buildModelVertices()
            vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<ModelVertex>.stride)
            uniformBuffer = device.makeBuffer(length: MemoryLayout<ObjUniforms>.stride)
            print("已上传 \(verts.count) 个展开顶点（\(triangleCount) 个三角形）到 GPU")
        } catch {
            print("初始化失败: \(error)"); exit(1)
        }
    }

    func draw(in view: MTKView) {
        angle += 0.015
        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        let model = rotationY(angle) * rotationX(0.4)
        let viewM = lookAt(eye: SIMD3(0, 0, 3.2), center: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
        let proj = perspective(fovY: 60.0 * .pi / 180, aspect: aspect, near: 0.01, far: 100)
        var uni = ObjUniforms(mvp: proj * viewM * model, model: model)
        memcpy(uniformBuffer.contents(), &uni, MemoryLayout<ObjUniforms>.stride)
        var light = SIMD3<Float>(0.6, 0.8, 0.5)

        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipelineState)
        enc.setDepthStencilState(depthState)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        enc.setFragmentBytes(&light, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangleCount * 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

class ObjModelAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Metal 24 · OBJ Model"
        window.center()
        window.contentViewController = ObjModelViewController()
        window.makeKeyAndOrderFront(nil)
    }
}

func runObjModel() {
    let app = NSApplication.shared
    let delegate = ObjModelAppDelegate()
    app.delegate = delegate
    app.run()
}
