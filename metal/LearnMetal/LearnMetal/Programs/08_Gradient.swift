import Cocoa
import Metal
import MetalKit

// Vertex structure for fullscreen quad
struct GradientVertex {
    var position: SIMD3<Float>
    var texCoord: SIMD2<Float>
}

// Main view controller
class GradientViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    
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
        metalView.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
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
    }
    
    func setupPipeline() {
        // Metal shader source
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct GradientVertexIn {
            float3 position;
            float2 texCoord;
        };
        
        struct GradientVertexOut {
            float4 position [[position]];
            float2 texCoord;
        };
        
        vertex GradientVertexOut gradient_vertex_main(
            constant GradientVertexIn *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            GradientVertexOut out;
            out.position = float4(vertices[vertexID].position, 1.0);
            out.texCoord = vertices[vertexID].texCoord;
            return out;
        }
        
        fragment float4 gradient_fragment_main(
            GradientVertexOut in [[stage_in]]
        ) {
            // Linear gradient from left to right
            float t = in.texCoord.x;
            
            // Colors: Red to Blue
            float3 color1 = float3(1.0, 0.0, 0.0);  // Red
            float3 color2 = float3(0.0, 0.0, 1.0);  // Blue
            
            // Smooth interpolation
            float smoothT = smoothstep(0.0, 1.0, t);
            float3 color = mix(color1, color2, smoothT);
            
            return float4(color, 1.0);
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
        guard let vertexFunction = library.makeFunction(name: "gradient_vertex_main"),
              let fragmentFunction = library.makeFunction(name: "gradient_fragment_main") else {
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
        // Fullscreen quad vertices (2 triangles)
        let vertices: [GradientVertex] = [
            // Triangle 1
            GradientVertex(position: SIMD3<Float>(-1.0,  1.0, 0.0), texCoord: SIMD2<Float>(0.0, 1.0)),
            GradientVertex(position: SIMD3<Float>(-1.0, -1.0, 0.0), texCoord: SIMD2<Float>(0.0, 0.0)),
            GradientVertex(position: SIMD3<Float>( 1.0,  1.0, 0.0), texCoord: SIMD2<Float>(1.0, 1.0)),
            // Triangle 2
            GradientVertex(position: SIMD3<Float>(-1.0, -1.0, 0.0), texCoord: SIMD2<Float>(0.0, 0.0)),
            GradientVertex(position: SIMD3<Float>( 1.0, -1.0, 0.0), texCoord: SIMD2<Float>(1.0, 0.0)),
            GradientVertex(position: SIMD3<Float>( 1.0,  1.0, 0.0), texCoord: SIMD2<Float>(1.0, 1.0))
        ]
        
        // Create vertex buffer
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<GradientVertex>.stride,
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
        
        // Draw fullscreen quad (2 triangles = 6 vertices)
        renderEncoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6
        )
        
        // End encoding
        renderEncoder.endEncoding()
        
        // Present and commit
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// App delegate
class GradientAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var viewController: GradientViewController!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create window
        let windowRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Color Gradient (Red to Blue)"
        window.center()
        
        // Create view controller
        viewController = GradientViewController()
        window.contentViewController = viewController
        
        window.makeKeyAndOrderFront(nil)
    }
}

// Function to run gradient rendering
func runGradient() {
    let app = NSApplication.shared
    let delegate = GradientAppDelegate()
    app.delegate = delegate
    app.run()
}
