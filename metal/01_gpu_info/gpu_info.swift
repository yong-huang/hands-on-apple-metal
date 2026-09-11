import Metal
import Foundation

func runGPUInfo() {
    

    // ⚙️ DEVICE PROPERTIES
    // ────────────────────────────────────────────────────────────
    // Is Low Power:             false
    // Is Headless:              false
    // Is Removable:             false

    // 🏷️ GPU FAMILY SUPPORT
    // ────────────────────────────────────────────────────────────
    // Metal 3:                  ✅
    // Common 1 (Apple Silicon): ✅
    // Common 2:                 ✅
    // Common 3:                 ✅
    // Mac 1:                    ✅
    // Mac 2:                    ✅
    // Mac Catalyst:             ❌
    // Mac Catalyst 2:           ❌

    // 🔧 FEATURE SUPPORT
    // ────────────────────────────────────────────────────────────
    // Tessellation:             ✅
    // Read-Write Textures:      ✅
    // Programmable Blending:    ✅
    // Raytracing:               ✅

    // 🖼️ SUPPORTED TEXTURE FORMATS (Sample)
    // ────────────────────────────────────────────────────────────
    // rgba8Unorm                ✅
    // rgba8Unorm_srgb           ✅
    // rgba16Unorm               ✅
    // rgba16Float               ✅
    // rgba32Float               ✅
    // depth32Float              ✅
    // depth24Unorm_stencil8     ✅
    // bgra8Unorm                ✅
    // bgra8Unorm_srgb           ✅

    // 🖥️ ADDITIONAL INFORMATION
    // ────────────────────────────────────────────────────────────
    // ✅ This GPU has display output
    // ⚡ High performance GPU (discrete)
    // 🔒 Built-in GPU

    // 📊 PERFORMANCE INDICATORS
    // ────────────────────────────────────────────────────────────
    // Current Allocated Memory: 458752 bytes
    //     (~0 MB)
    // Max Threadgroup Memory:   32768 bytes

    // ══════════════════════════════════════════════════════════
    // Total GPU Information: Apple M5 Pro
    // ══════════════════════════════════════════════════════════
    
    guard let device = MTLCreateSystemDefaultDevice() else {
        print("Failed to get default Metal device")
        return
    }
    
    print("╔══════════════════════════════════════════════════════════════╗")
    print("║              GPU DEVICE INFORMATION                         ║")
    print("╚══════════════════════════════════════════════════════════════╝")
    print()
    
    // 1. Basic Device Info
    print("📱 BASIC DEVICE INFO")
    print("────────────────────────────────────────────────────────────")
    print("  Device Name:              \(device.name)")
    print("  Device Registry ID:       \(device.registryID)")
    
    // 2. Thread and Compute Capabilities
    print("\n🧵 THREAD & COMPUTE CAPABILITIES")
    print("────────────────────────────────────────────────────────────")
    let maxThreads = device.maxThreadsPerThreadgroup
    print("  Max Threads Per Threadgroup:")
    print("    Width:  \(maxThreads.width)")
    print("    Height: \(maxThreads.height)")
    print("    Depth:  \(maxThreads.depth)")
    
    // Getting thread execution width through maxThreadsPerThreadgroup
    print("  Thread Execution Width:   \(maxThreads.width)")
    
    if #available(macOS 10.14, iOS 12.0, *) {
        print("  Max Threadgroup Memory Length: \(device.maxThreadgroupMemoryLength) bytes")
        let lengthInKB = device.maxThreadgroupMemoryLength / 1024
        let lengthInMB = device.maxThreadgroupMemoryLength / (1024 * 1024)
        if lengthInMB > 0 {
            print("    (~\(lengthInMB) MB)")
        } else if lengthInKB > 0 {
            print("    (~\(lengthInKB) KB)")
        }
    }
    
    // 3. Memory Information
    print("\n💾 MEMORY INFORMATION")
    print("────────────────────────────────────────────────────────────")
    if #available(macOS 10.15, iOS 13.0, *) {
        print("  Has Unified Memory:       \(device.hasUnifiedMemory)")
        print("  Recommended Max Working Set Size:")
        let workingSet = device.recommendedMaxWorkingSetSize
        print("    \(workingSet) bytes")
        let workingSetGB = Double(workingSet) / 1_073_741_824.0
        print("    (~\(String(format: "%.2f", workingSetGB)) GB)")
    }
    
    if #available(macOS 10.13, iOS 11.0, *) {
        print("  Max Buffer Length:        \(device.maxBufferLength) bytes")
        let maxBufferMB = device.maxBufferLength / (1024 * 1024)
        print("    (~\(maxBufferMB) MB)")
    }
    
    // 4. Device Properties
    print("\n⚙️ DEVICE PROPERTIES")
    print("────────────────────────────────────────────────────────────")
    print("  Is Low Power:             \(device.isLowPower)")
    print("  Is Headless:              \(device.isHeadless)")
    print("  Is Removable:             \(device.isRemovable)")
    
    // 5. GPU Family Support
    print("\n🏷️ GPU FAMILY SUPPORT")
    print("────────────────────────────────────────────────────────────")
    
    if #available(macOS 10.15, iOS 13.0, *) {
        print("  Metal 3:                  \(device.supportsFamily(.metal3) ? "✅" : "❌")")
        print("  Common 1 (Apple Silicon): \(device.supportsFamily(.common1) ? "✅" : "❌")")
        print("  Common 2:                 \(device.supportsFamily(.common2) ? "✅" : "❌")")
        print("  Common 3:                 \(device.supportsFamily(.common3) ? "✅" : "❌")")
    }
    
    if #available(macOS 10.14, iOS 12.0, *) {
        print("  Mac 1:                    \(device.supportsFamily(.mac1) ? "✅" : "❌")")
        print("  Mac 2:                    \(device.supportsFamily(.mac2) ? "✅" : "❌")")
    }
    
    #if os(macOS)
    if #available(macOS 11.0, *) {
        print("  Mac Catalyst:             \(device.supportsFamily(.macCatalyst1) ? "✅" : "❌")")
        print("  Mac Catalyst 2:           \(device.supportsFamily(.macCatalyst2) ? "✅" : "❌")")
    }
    #endif
    
    // 6. Feature Support (macOS specific)
    print("\n🔧 FEATURE SUPPORT")
    print("────────────────────────────────────────────────────────────")
    
    #if os(macOS)
    if #available(macOS 10.14, *) {
        print("  Tessellation:             \(device.supportsFeatureSet(.macOS_GPUFamily1_v1) ? "✅" : "❌")")
        print("  Read-Write Textures:      \(device.supportsFeatureSet(.macOS_GPUFamily1_v2) ? "✅" : "❌")")
        print("  Programmable Blending:    \(device.supportsFeatureSet(.macOS_GPUFamily1_v3) ? "✅" : "❌")")
    }
    
    if #available(macOS 10.15, *) {
        print("  Raytracing:               \(device.supportsFeatureSet(.macOS_GPUFamily1_v4) ? "✅" : "❌")")
    }
    #else
    if #available(iOS 10.0, *) {
        print("  Read-Write Textures:      \(device.supportsFeatureSet(.iOS_GPUFamily1_v1) ? "✅" : "❌")")
    }
    #endif
    
    // 7. Supported Texture Formats (Sample)
    print("\n🖼️ SUPPORTED TEXTURE FORMATS (Sample)")
    print("────────────────────────────────────────────────────────────")
    let formats: [MTLPixelFormat] = [
        .rgba8Unorm, .rgba8Unorm_srgb,
        .rgba16Unorm, .rgba16Float,
        .rgba32Float,
        .depth32Float, .depth24Unorm_stencil8,
        .bgra8Unorm, .bgra8Unorm_srgb
    ]
    
    // Helper function to get pixel format name
    func pixelFormatName(_ format: MTLPixelFormat) -> String {
        switch format {
        case .rgba8Unorm: return "rgba8Unorm"
        case .rgba8Unorm_srgb: return "rgba8Unorm_srgb"
        case .rgba16Unorm: return "rgba16Unorm"
        case .rgba16Float: return "rgba16Float"
        case .rgba32Float: return "rgba32Float"
        case .depth32Float: return "depth32Float"
        case .depth24Unorm_stencil8: return "depth24Unorm_stencil8"
        case .bgra8Unorm: return "bgra8Unorm"
        case .bgra8Unorm_srgb: return "bgra8Unorm_srgb"
        default: return "unknown"
        }
    }
    
    for format in formats {
        let supports = device.supportsTextureSampleCount(1)
        let formatName = pixelFormatName(format)
        let status = supports ? "✅" : "❌"
        // Use string interpolation instead of format specifier
        let paddedName = formatName.padding(toLength: 25, withPad: " ", startingAt: 0)
        print("  \(paddedName) \(status)")
    }
    
    // 8. Headless GPU Detection
    print("\n🖥️ ADDITIONAL INFORMATION")
    print("────────────────────────────────────────────────────────────")
    if device.isHeadless {
        print("  ⚠️  This GPU is headless (no display output)")
    } else {
        print("  ✅ This GPU has display output")
    }
    
    if device.isLowPower {
        print("  🔋 Low power GPU (integrated)")
    } else {
        print("  ⚡ High performance GPU (discrete)")
    }
    
    if device.isRemovable {
        print("  🔌 Removable/External GPU (eGPU)")
    } else {
        print("  🔒 Built-in GPU")
    }
    
    // 9. Maximum Threadgroup Memory
    print("\n📊 PERFORMANCE INDICATORS")
    print("────────────────────────────────────────────────────────────")
    if #available(macOS 10.15, iOS 13.0, *) {
        let currentAllocated = device.currentAllocatedSize
        print("  Current Allocated Memory: \(currentAllocated) bytes")
        if currentAllocated > 0 {
            let allocatedMB = currentAllocated / (1024 * 1024)
            print("    (~\(allocatedMB) MB)")
        }
    }
    
    if #available(macOS 10.14, iOS 12.0, *) {
        print("  Max Threadgroup Memory:   \(device.maxThreadgroupMemoryLength) bytes")
    }
    
    print("\n" + String(repeating: "═", count: 58))
    print("  Total GPU Information: \(device.name)")
    print(String(repeating: "═", count: 58))
    print()
}

