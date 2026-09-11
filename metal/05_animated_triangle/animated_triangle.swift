import Cocoa
import Metal
import MetalKit
import simd

// AnimatedVertex 结构体：
// - position	SIMD3<Float>	顶点在三维空间中的位置，包含 x、y、z 三个浮点坐标值
// - color	SIMD4<Float>	顶点的颜色，包含红 (r)、绿 (g)、蓝 (b) 和透明度 (a) 四个分量

// SIMD3/SIMD4：
// - SIMD = Single Instruction, Multiple Data（单指令多数据）
// - SIMD3<Float> = 长度为 3 的浮点向量类型，用于存储三维坐标或 RGB 颜色
// - SIMD4<Float> = 长度为 4 的浮点向量类型，用于存储四维位置 (x,y,z,w) 或 RGBA 颜色

// 为什么需要这个结构？
// Metal 渲染管线需要将顶点数据从 CPU（Swift）传输到 GPU，GPU 通过顶点着色器处理每个顶点。
// AnimatedVertex 定义了传递给 GPU 的数据格式：位置决定几何形状，颜色用于片元着色阶段输出最终像素颜色。

// Vertex structure
struct AnimatedVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

// Uniform structure for transformation matrix
struct Uniforms {
    var modelViewProjectionMatrix: simd_float4x4
}

// Main view controller
class AnimatedTriangleViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var uniformBuffer: MTLBuffer!
    var startTime: CFTimeInterval!
    
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
        metalView.enableSetNeedsDisplay = false
        view.addSubview(metalView)
        
        // Setup command queue
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Failed to create command queue")
        }
        self.commandQueue = commandQueue
        
        // Setup pipeline
        setupPipeline()
        
        // Setup vertex data
        setupVertexData()
        
        // Setup uniform buffer
        setupUniformBuffer()
        
        // Record start time
        startTime = CACurrentMediaTime()
        
        // Start animation loop
        metalView.isPaused = false
    }
    
    func setupPipeline() {
        // Metal shader source
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct AnimatedVertexIn {
            float3 position;
            float4 color;
        };
        
        struct AnimatedVertexOut {
            float4 position [[position]];
            float4 color;
        };
        
        struct Uniforms {
            float4x4 modelViewProjectionMatrix;
        };
        
        vertex AnimatedVertexOut animated_vertex_main(
            constant AnimatedVertexIn *vertices [[buffer(0)]],
            constant Uniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            AnimatedVertexOut out;
            float4 position = float4(vertices[vertexID].position, 1.0);
            out.position = uniforms.modelViewProjectionMatrix * position;
            out.color = vertices[vertexID].color;
            return out;
        }
        
        fragment float4 animated_fragment_main(
            AnimatedVertexOut in [[stage_in]]
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
        guard let vertexFunction = library.makeFunction(name: "animated_vertex_main"),
              let fragmentFunction = library.makeFunction(name: "animated_fragment_main") else {
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
        let vertices: [AnimatedVertex] = [
            AnimatedVertex(position: SIMD3<Float>( 0.0,  0.5, 0.0), color: SIMD4<Float>(1.0, 0.0, 0.0, 1.0)), // Top - Red
            AnimatedVertex(position: SIMD3<Float>(-0.5, -0.5, 0.0), color: SIMD4<Float>(0.0, 1.0, 0.0, 1.0)), // Bottom Left - Green
            AnimatedVertex(position: SIMD3<Float>( 0.5, -0.5, 0.0), color: SIMD4<Float>(0.0, 0.0, 1.0, 1.0))  // Bottom Right - Blue
        ]
        
        // Create vertex buffer
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<AnimatedVertex>.stride,
            options: .storageModeShared
        )
    }
    
    func setupUniformBuffer() {

        // Uniform Buffer：
        // 这是一个特殊的缓冲区（MTLBuffer），用于存储"uniform data"——即着色器需要访问但不会随每个顶点变化的数据。
        // 在这个例子中，它存储的是变换矩阵（modelViewProjectionMatrix）。

        // 为什么需要它？
        // - GPU 的顶点着色器需要通过 uniform 变量访问变换矩阵。
        // - CPU 需要将这个矩阵传递给 GPU，而 Uniform Buffer 就是传递这种数据的通道。
        // - 在动画循环中（draw(in:)），会调用 updateUniforms() 来实时更新旋转角度对应的矩阵，然后写入到这个 buffer。
        // 简单来说：它是 CPU 和 GPU 之间传递变换数据的"管道"。

        // Create uniform buffer with initial identity matrix
        var initialUniforms = Uniforms(modelViewProjectionMatrix: matrix_identity_float4x4)
        uniformBuffer = device.makeBuffer(
            bytes: &initialUniforms,
            length: MemoryLayout<Uniforms>.size,
            options: .storageModeShared
        )
    }
    
    func updateUniforms() {
        guard let startTime = startTime else { return }
        
        let currentTime = CACurrentMediaTime()
        let elapsedTime = Float(currentTime - startTime)
        
        // Create rotation matrix around Z-axis
        let angle = elapsedTime * 1.5 // Rotate at 1.5 radians per second
        let rotationMatrix = simd_float4x4(
            simd_float4(cos(angle), -sin(angle), 0, 0),
            simd_float4(sin(angle),  cos(angle), 0, 0),
            simd_float4(0, 0, 1, 0),
            simd_float4(0, 0, 0, 1)
        )
        
        // Scale down slightly to keep triangle in view during rotation
        let scale: Float = 0.9
        let scaleMatrix = simd_float4x4(
            simd_float4(scale, 0, 0, 0),
            simd_float4(0, scale, 0, 0),
            simd_float4(0, 0, scale, 0),
            simd_float4(0, 0, 0, 1)
        )
        
        // Combine transformations: rotation * scale
        let transformMatrix = rotationMatrix * scaleMatrix
        
        // Update uniform buffer
        var uniforms = Uniforms(modelViewProjectionMatrix: transformMatrix)
        memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.size)
    }
    
    // MTKViewDelegate methods
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handle view size change if needed
    }
    
    func draw(in view: MTKView) {
        // Update uniforms with current rotation
        updateUniforms()
        
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
        
        // Set vertex buffer at index 0
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        
        // Set uniform buffer at index 1
        renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        
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

// App delegate
class AnimatedTriangleAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var viewController: AnimatedTriangleViewController!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create window
        let windowRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Animated Rotating Triangle"
        window.center()
        
        // Create view controller
        viewController = AnimatedTriangleViewController()
        window.contentViewController = viewController
        
        window.makeKeyAndOrderFront(nil)
    }
}

// Function to run animated triangle
func runAnimatedTriangle() {
    let app = NSApplication.shared
    let delegate = AnimatedTriangleAppDelegate()
    app.delegate = delegate
    app.run()
}
