import Foundation

// 导入其他文件（Swift 会自动导入同模块下的所有文件）

// Main function
func main() {
//    // Run GPU info
//    print("=== Running GPU Info ===")
//    runGPUInfo()
//    print("\n")
//    
//    // Run Command Queue
//    print("=== Running Command Queue ===")
//    runCommandQueue()
//    print("\n")
//    
//    // Run Triangle Rendering
//    print("=== Running Triangle Rendering ===")
//    runTriangle()
//    
//    // Run Rectangle Rendering
//    print("=== Running Rectangle Rendering with Index Buffer ===")
//    runRectangle()
//    
    // Set environment to suppress system errors
    setenv("APPINTENTS_DISABLE", "1", 1)
    
    print("=== Running Animated Rotating Triangle ===")
    runAnimatedTriangle()
//
//    // Set environment to suppress system errors
//    setenv("APPINTENTS_DISABLE", "1", 1)
//    
//    print("=== Running Chessboard Pattern ===")
//    runChessboard()
//
//    // Set environment to suppress system errors
//    setenv("APPINTENTS_DISABLE", "1", 1)
//    
//    print("=== Running Circle Drawing ===")
//    runCircle()
//    
//    // Set environment to suppress system errors
//    setenv("APPINTENTS_DISABLE", "1", 1)
//    
//    print("=== Running Color Gradient ===")
//    runGradient()
//    
//    // Set environment to suppress system errors
//    setenv("APPINTENTS_DISABLE", "1", 1)
//    
//    print("=== Running Texture Mapping ===")
//    runTexture()
}

main()
