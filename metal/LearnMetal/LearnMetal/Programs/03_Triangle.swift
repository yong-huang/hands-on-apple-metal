import Cocoa
import Metal
import MetalKit

// Vertex structure
struct Vertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

// Main view controller
class TriangleViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // 20260809:
        // 大致流程：
        // 1、Setup Metal
        // 2、Setup MTKView
        // 3、Setup pipeline        
        // 4、Setup vertex data

        // Setup Metal
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        self.device = device
        
        // 20260809:
        // MTKView 是渲染上下文 - 它负责：
        // - 管理 Metal 设备（device）
        // - 创建 drawable（实际的金属纹理/表面）
        // - 处理窗口大小变化
        // - 调用 draw(in:) 方法触发每一帧的绘制

        // drawable 才是真正的"画布" - MTKView 会创建一个或多个 drawable，这是 Metal 实际渲染的目标表面。
        // 每次 commit() 时，MTKView 会把当前 drawable 呈现到屏幕上。
        
        // draw(in:) 是画画的动作 - 在这个方法里你：
        // - 创建命令缓冲区（command buffer）
        // - 设置管线状态、顶点数据
        // - 执行绘制操作
        // - 提交命令让 GPU 渲染

        // 所以类比来说：
        // - MTKView = 画板框架，负责管理整个绘画流程
        // - drawable = 实际的纸张/画布（纹理）
        // - draw(in:) + 编码器 = 你画画的过程

        // Setup MTKView
        metalView = MTKView(frame: view.bounds, device: device)
        metalView.autoresizingMask = [.width, .height]
        metalView.delegate = self
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
        view.addSubview(metalView)
        
        // 20260809: 在draw中会用到commandQueue

        // Setup command queue
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create command queue")
        }
        self.commandQueue = commandQueue
        
        // Setup pipeline
        setupPipeline()
        
        // Setup vertex data
        setupVertexData()
    }
    
    func setupPipeline() {

        // 20260809:
        // 顶点着色器：它的核心任务是处理 3D 模型中每个顶点的原始数据，比如位置、颜色、法线等，然后输出变换后的顶点位置和其他后续阶段（如片元着色器）需要的数据。

        // 在 Apple Metal 图形 API 中，除了**顶点着色器 (Vertex Shader)**外，还有以下几种主要类型的着色器：
        
        // 1. 片元着色器 (Fragment Shader / Pixel Shader)
        // - 每个像素都会调用一次
        // - 负责计算最终要渲染到帧缓冲区的颜色值
        // - 在 Metal 中通常使用 fragment 函数命名
        
        // 2. 几何着色器 (Geometry Shader)（可选）
        // - 将顶点数据转换为图元（如三角形、线、点）
        // - 可以将一个或多个顶点转换成新的图元
        // - Metal 支持但使用较少，因为现代 GPU 硬件对它的优化有限
        
        // 3. 计算着色器 (Compute Shader)
        // - 用于通用并行计算任务
        // - 不直接渲染图形，而是处理数据（如图像后处理、物理模拟）
        // - 在 Metal 中通常使用 kernel 函数命名
        
        // 4. 统一着色器 (Unified Shader)
        // - Metal 的硬件架构特点：现代 GPU 拥有统一的渲染管道和计算单元
        // - Vertex、Fragment、Compute 功能由同一组硬件执行，通过调度决定用途
        // - 开发者编写不同阶段的 shader（vertex/fragment/compute），Metal 负责在合适的时候调用
        
        // 5. 其他相关着色器类型
        // - ** tessellation shaders (细分着色器)**：将图元细分为更小的图元（顶点和几何着色器的组合）
        // - domain eval shaders (域评估着色器)：处理细分后的片元，输出最终位置数据

        // Metal shader source
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct VertexIn {
            float3 position;
            float4 color;
        };
        
        struct VertexOut {
            float4 position [[position]];
            float4 color;
        };
        
        vertex VertexOut vertex_main(
            constant VertexIn *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            out.position = float4(vertices[vertexID].position, 1.0);
            out.color = vertices[vertexID].color;
            return out;
        }
        
        fragment float4 fragment_main(
            VertexOut in [[stage_in]]
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
        guard let vertexFunction = library.makeFunction(name: "vertex_main"),
              let fragmentFunction = library.makeFunction(name: "fragment_main") else {
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
    
    func setupVertexData() {
        // Define vertices for a triangle
        let vertices: [Vertex] = [
            Vertex(position: SIMD3<Float>( 0.0,  0.5, 0.0), color: SIMD4<Float>(1.0, 0.0, 0.0, 1.0)), // Top - Red
            Vertex(position: SIMD3<Float>(-0.5, -0.5, 0.0), color: SIMD4<Float>(0.0, 1.0, 0.0, 1.0)), // Bottom Left - Green
            Vertex(position: SIMD3<Float>( 0.5, -0.5, 0.0), color: SIMD4<Float>(0.0, 0.0, 1.0, 1.0))  // Bottom Right - Blue
        ]
        
        // Create vertex buffer
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Vertex>.stride,
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
        
        // Set pipeline state
        renderEncoder.setRenderPipelineState(pipelineState)
        
        // Set vertex buffer
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
        // Draw triangle
        renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 3
        )
        
        // End encoding
        renderEncoder.endEncoding()
        
        // Present and commit
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// App delegate to run the application
class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var viewController: TriangleViewController!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create window
        let windowRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Metal Triangle"
        window.center()
        
        // Create view controller
        viewController = TriangleViewController()
        window.contentViewController = viewController
        
        window.makeKeyAndOrderFront(nil)
    }
}

// Function to run triangle rendering
func runTriangle() {

    // 20260809:
    // 大致套路：
    // 1、拿app对象
    // 2、app.delegate = delegate
    // 3、delegate：创建窗口，再viewController = TriangleViewController()
    // 4、具体逻辑在TriangleViewController中实现

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
