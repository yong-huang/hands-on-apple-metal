import Cocoa
import Metal
import MetalKit

// Vertex structure with unique name
struct RectangleVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

// Main view controller
class RectangleViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var indexBuffer: MTLBuffer!
    var indexCount: Int!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Setup Metal
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device
        
        // Setup MTKView
        metalView = MTKView(frame: view.bounds, device: device)
        metalView.autoresizingMask = [.width, .height]
        metalView.delegate = self
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        view.addSubview(metalView)
        
        // Setup command queue
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create command queue")
        }
        self.commandQueue = commandQueue
        
        // Setup pipeline
        setupPipeline()
        
        // Setup vertex and index data
        setupVertexAndIndexData()
    }
    
    func setupPipeline() {
        // Metal shader source
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct RectangleVertexIn {
            float3 position;
            float4 color;
        };
        
        struct RectangleVertexOut {
            float4 position [[position]];
            float4 color;
        };
        
        vertex RectangleVertexOut rectangle_vertex_main(
            constant RectangleVertexIn *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            RectangleVertexOut out;
            out.position = float4(vertices[vertexID].position, 1.0);
            out.color = vertices[vertexID].color;
            return out;
        }
        
        fragment float4 rectangle_fragment_main(
            RectangleVertexOut in [[stage_in]]
        ) {
            return in.color;
        }
        """
        
        // Create library from source
        let options = MTLCompileOptions()
        options.fastMathEnabled = true
        
        var library: MTLLibrary?
        do {
            library = try device.makeLibrary(source: shaderSource, options: options)
        } catch {
            fatalError("Failed to compile shader: \(error)")
        }
        
        guard let library = library else {
            fatalError("Failed to create library")
        }
        
        // Get vertex and fragment functions
        guard let vertexFunction = library.makeFunction(name: "rectangle_vertex_main"),
              let fragmentFunction = library.makeFunction(name: "rectangle_fragment_main") else {
            fatalError("Failed to create shader functions")
        }
        
        // Create pipeline descriptor
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        
        // Create pipeline state
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create pipeline state: \(error)")
        }
    }
    
    func setupVertexAndIndexData() {

        // 顶点坐标
        // NDC（标准化设备坐标）范围：[-1, +1] × [-1, +1]
        // - (-0.8, 0.6) → 左上角红色矩形
        // - (0.8, 0.6) → 右上角绿色矩形
        // - (-0.8,-0.6) → 左下角蓝色矩形
        // - (0.8,-0.6) → 右下角黄色矩形

        // Define 4 vertices for a rectangle (in NDC coordinates)
        let vertices: [RectangleVertex] = [
            RectangleVertex(position: SIMD3<Float>(-0.8,  0.6, 0.0), color: SIMD4<Float>(1.0, 0.0, 0.0, 1.0)), // Top-Left - Red
            RectangleVertex(position: SIMD3<Float>( 0.8,  0.6, 0.0), color: SIMD4<Float>(0.0, 1.0, 0.0, 1.0)), // Top-Right - Green
            RectangleVertex(position: SIMD3<Float>(-0.8, -0.6, 0.0), color: SIMD4<Float>(0.0, 0.0, 1.0, 1.0)), // Bottom-Left - Blue
            RectangleVertex(position: SIMD3<Float>( 0.8, -0.6, 0.0), color: SIMD4<Float>(1.0, 1.0, 0.0, 1.0))  // Bottom-Right - Yellow
        ]
        
        // Create vertex buffer
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<RectangleVertex>.stride,
            options: .storageModeShared
        )
        
        // Define indices for triangle strip
        // Triangle strip order: v0, v1, v2, v3
        // This creates two triangles: (v0, v1, v2) and (v1, v2, v3)
        let indices: [UInt16] = [
            0, 1, 2, 3
        ]
        
        indexCount = indices.count
        
        // Create index buffer
        indexBuffer = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt16>.size,
            options: .storageModeShared
        )
    }
    
    // MTKViewDelegate methods
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle view size change if needed
    }
    
    func draw(in view: MTKView) {
        // Get current drawable and render pass descriptor
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor else {
            return
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        
        // Create render command encoder
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        
        // 渲染流程
        // - 创建 pipeline state → 绑定 vertex/fragment function
        // - 设置 vertex buffer → 传递 4 个顶点数据
        // - 绘制三角形条带 → drawIndexedPrimitives(type: .triangleStrip)
        //   索引：[0, 1, 2, 3]
        //   生成两个三角形：(v0,v1,v2) + (v1,v2,v3)

        // Set pipeline state
        renderEncoder.setRenderPipelineState(pipelineState)
        
        // Set vertex buffer
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
        // 调用drawIndexedPrimitives，用两个三角形构建一个矩形

        // Triangle Strip 的工作规则非常简单：
        // - 前 3 个顶点：形成第一个三角形
        // - 之后的每个新顶点：与前两个顶点形成一个新的三角形

        // 画三角形直接调用：
        // renderEncoder.drawPrimitives(
        //     type: .triangle,
        //     vertexStart: 0,
        //     vertexCount: 3
        // )

        // Draw rectangle using triangle strip with index buffer
        renderEncoder.drawIndexedPrimitives(
            type: .triangleStrip,
            indexCount: indexCount,
            indexType: .uint16,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )
        
        // End encoding
        renderEncoder.endEncoding()
        
        // Present and commit
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// App delegate with unique name
class RectangleAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var viewController: RectangleViewController!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // 创建窗口，后边就在这个窗口中绘图
        // Create window
        let windowRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Metal Rectangle (Index Buffer + Triangle Strip)"
        window.center()
        
        // Create view controller
        viewController = RectangleViewController()
        window.contentViewController = viewController
        
        window.makeKeyAndOrderFront(nil)
    }
}

// Function to run rectangle rendering
func runRectangle() {
    let app = NSApplication.shared
    let delegate = RectangleAppDelegate()
    app.delegate = delegate
    app.run()
}
