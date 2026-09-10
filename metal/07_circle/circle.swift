import Cocoa
import Metal
import MetalKit

// Vertex structure for fullscreen quad
struct CircleVertex {
    var position: SIMD3<Float>
    var texCoord: SIMD2<Float>
}

// Main view controller
class CircleViewController: NSViewController, MTKViewDelegate {
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
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
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
        
        struct CircleVertexIn {
            float3 position;
            float2 texCoord;
        };
        
        struct CircleVertexOut {
            float4 position [[position]];
            float2 texCoord;
        };
        
        vertex CircleVertexOut circle_vertex_main(
            constant CircleVertexIn *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            CircleVertexOut out;
            out.position = float4(vertices[vertexID].position, 1.0);
            out.texCoord = vertices[vertexID].texCoord;
            return out;
        }
        
        fragment float4 circle_fragment_main(
            CircleVertexOut in [[stage_in]]
        ) {
            // Transform UV coordinates to center origin
            float2 uv = in.texCoord * 2.0 - 1.0;
            
            // Adjust for aspect ratio to keep circle round
            float aspect = 1.0; // Will be passed as uniform later
            uv.x *= aspect;
            
            // Calculate distance from center
            float dist = length(uv);
            
            // Smooth circle with anti-aliasing
            float radius = 0.8;
            float smoothness = 0.02;
            float circle = 1.0 - smoothstep(radius - smoothness, radius + smoothness, dist);
            
            // Colors
            float3 circleColor = float3(0.0, 0.6, 1.0);  // Blue
            float3 bgColor = float3(0.1, 0.1, 0.1);      // Dark background
            
            // Mix based on circle mask
            float3 color = mix(bgColor, circleColor, circle);
            
            // Add subtle glow
            float glow = exp(-dist * 4.0) * 0.3;
            color += glow * circleColor;
            
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
        guard let vertexFunction = library.makeFunction(name: "circle_vertex_main"),
              let fragmentFunction = library.makeFunction(name: "circle_fragment_main") else {
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
        let vertices: [CircleVertex] = [
            // Triangle 1
            CircleVertex(position: SIMD3<Float>(-1.0,  1.0, 0.0), texCoord: SIMD2<Float>(0.0, 1.0)),
            CircleVertex(position: SIMD3<Float>(-1.0, -1.0, 0.0), texCoord: SIMD2<Float>(0.0, 0.0)),
            CircleVertex(position: SIMD3<Float>( 1.0,  1.0, 0.0), texCoord: SIMD2<Float>(1.0, 1.0)),
            // Triangle 2
            CircleVertex(position: SIMD3<Float>(-1.0, -1.0, 0.0), texCoord: SIMD2<Float>(0.0, 0.0)),
            CircleVertex(position: SIMD3<Float>( 1.0, -1.0, 0.0), texCoord: SIMD2<Float>(1.0, 0.0)),
            CircleVertex(position: SIMD3<Float>( 1.0,  1.0, 0.0), texCoord: SIMD2<Float>(1.0, 1.0))
        ]
        
        // Create vertex buffer
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<CircleVertex>.stride,
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
class CircleAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var viewController: CircleViewController!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create window
        let windowRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Circle Drawing (Fragment Shader)"
        window.center()
        
        // Create view controller
        viewController = CircleViewController()
        window.contentViewController = viewController
        
        window.makeKeyAndOrderFront(nil)
    }
}

// Function to run circle rendering
func runCircle() {
    let app = NSApplication.shared
    let delegate = CircleAppDelegate()
    app.delegate = delegate
    app.run()
}
