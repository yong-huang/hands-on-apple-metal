import Cocoa
import Metal
import MetalKit

// Vertex structure for textured quad
struct TextureVertex {
    var position: SIMD3<Float>
    var texCoord: SIMD2<Float>
}

// Main view controller
class TextureViewController: NSViewController, MTKViewDelegate {
    var metalView: MTKView!
    var device: MTLDevice!
    var commandQueue: MTLCommandQueue!
    var pipelineState: MTLRenderPipelineState!
    var vertexBuffer: MTLBuffer!
    var texture: MTLTexture!
    
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
        
        // Load texture
        loadTexture()
        
        // Setup pipeline
        setupPipeline()
        
        // Setup vertex data
        setupVertexData()
    }
    
    func loadTexture() {
        // Create a simple checkerboard texture programmatically
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 256,
            height: 256,
            mipmapped: false
        )
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            fatalError("Failed to create texture")
        }
        
        // Generate checkerboard pattern
        let pixelCount = 256 * 256
        var pixels = [UInt8](repeating: 0, count: pixelCount * 4)
        
        let squareSize = 32
        for y in 0..<256 {
            for x in 0..<256 {
                let isBlack = ((x / squareSize) + (y / squareSize)) % 2 == 0
                let index = (y * 256 + x) * 4
                
                if isBlack {
                    pixels[index] = 40     // R
                    pixels[index + 1] = 40  // G
                    pixels[index + 2] = 40  // B
                    pixels[index + 3] = 255 // A
                } else {
                    pixels[index] = 200     // R
                    pixels[index + 1] = 200 // G
                    pixels[index + 2] = 200 // B
                    pixels[index + 3] = 255 // A
                }
            }
        }
        
        // Upload pixel data to texture
        let region = MTLRegionMake2D(0, 0, 256, 256)
        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: 256 * 4
        )
        
        self.texture = texture
    }
    
    func setupPipeline() {
        // Metal shader source
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        struct TextureVertexIn {
            float3 position;
            float2 texCoord;
        };
        
        struct TextureVertexOut {
            float4 position [[position]];
            float2 texCoord;
        };
        
        vertex TextureVertexOut texture_vertex_main(
            constant TextureVertexIn *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            TextureVertexOut out;
            out.position = float4(vertices[vertexID].position, 1.0);
            out.texCoord = vertices[vertexID].texCoord;
            return out;
        }
        
        fragment float4 texture_fragment_main(
            TextureVertexOut in [[stage_in]],
            texture2d<float> texture [[texture(0)]],
            sampler sampler2D [[sampler(0)]]
        ) {
            float4 color = texture.sample(sampler2D, in.texCoord);
            return color;
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
        guard let vertexFunction = library.makeFunction(name: "texture_vertex_main"),
              let fragmentFunction = library.makeFunction(name: "texture_fragment_main") else {
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
        // Rect vertices with texture coordinates
        let vertices: [TextureVertex] = [
            // Triangle 1
            TextureVertex(position: SIMD3<Float>(-0.8,  0.6, 0.0), texCoord: SIMD2<Float>(0.0, 1.0)),
            TextureVertex(position: SIMD3<Float>(-0.8, -0.6, 0.0), texCoord: SIMD2<Float>(0.0, 0.0)),
            TextureVertex(position: SIMD3<Float>( 0.8,  0.6, 0.0), texCoord: SIMD2<Float>(1.0, 1.0)),
            // Triangle 2
            TextureVertex(position: SIMD3<Float>(-0.8, -0.6, 0.0), texCoord: SIMD2<Float>(0.0, 0.0)),
            TextureVertex(position: SIMD3<Float>( 0.8, -0.6, 0.0), texCoord: SIMD2<Float>(1.0, 0.0)),
            TextureVertex(position: SIMD3<Float>( 0.8,  0.6, 0.0), texCoord: SIMD2<Float>(1.0, 1.0))
        ]
        
        // Create vertex buffer
        vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<TextureVertex>.stride,
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
        
        // Set texture and sampler
        renderEncoder.setFragmentTexture(texture, index: 0)
        
        // Create sampler descriptor
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            fatalError("Failed to create sampler")
        }
        
        renderEncoder.setFragmentSamplerState(sampler, index: 0)
        
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
class TextureAppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var viewController: TextureViewController!
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Create window
        let windowRect = NSRect(x: 0, y: 0, width: 800, height: 600)
        window = NSWindow(
            contentRect: windowRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Texture Mapping (Checkerboard)"
        window.center()
        
        // Create view controller
        viewController = TextureViewController()
        window.contentViewController = viewController
        
        window.makeKeyAndOrderFront(nil)
    }
}

// Function to run texture rendering
func runTexture() {
    let app = NSApplication.shared
    let delegate = TextureAppDelegate()
    app.delegate = delegate
    app.run()
}
