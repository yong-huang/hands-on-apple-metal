// 02 · SwiftUI Shader 特效：三个自写 shader 由 Slider 实时驱动
// 不写渲染管线：Effects.metal 编进 default.metallib，SwiftUI 的
// colorEffect / distortionEffect / layerEffect 直接调用它们。
// 自检在独立进程 shader_check 中完成（见 shader_check.swift）。
import SwiftUI
import MetalKit


// MARK: - 程序化生成测试图（无外部资产，克隆即跑）
func makeDemoImage() -> NSImage {
    let size = NSSize(width: 640, height: 400)
    let img = NSImage(size: size)
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    // 天空渐变
    let colors = [NSColor(calibratedWhite: 0.15, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.4, green: 0.7, blue: 1.0, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    // 太阳 + 山
    ctx.setFillColor(NSColor.systemYellow.cgColor)
    ctx.fillEllipse(in: NSRect(x: 480, y: 260, width: 90, height: 90))
    ctx.setFillColor(NSColor(calibratedWhite: 0.2, alpha: 1).cgColor)
    ctx.move(to: .zero); ctx.addLine(to: CGPoint(x: 200, y: 220)); ctx.addLine(to: CGPoint(x: 380, y: 0)); ctx.addLine(to: .zero)
    ctx.closePath(); ctx.fillPath()
    ctx.setFillColor(NSColor(calibratedWhite: 0.3, alpha: 1).cgColor)
    ctx.move(to: CGPoint(x: 640, y: 0)); ctx.addLine(to: CGPoint(x: 420, y: 180)); ctx.addLine(to: CGPoint(x: 640, y: 260)); ctx.closePath(); ctx.fillPath()
    img.unlockFocus()
    return img
}

// MARK: - 主界面
struct ContentView: View {
    @State private var tone: Float = 0       // ① 双色调强度
    @State private var wave: Float = 0       // ② 涟漪波幅
    @State private var glitch: Float = 0     // ③ 错位幅度
    @State private var t = Date().timeIntervalSince1970
    let demo = Image(nsImage: makeDemoImage()).interpolation(.high)

    var body: some View {
        VStack(spacing: 14) {
            // 三个 shader 按参数叠加：调色 → 涟漪 → 错位
            demo
                .resizable().aspectRatio(contentMode: .fit)
                .frame(maxHeight: 380)
                .colorEffect(ShaderLibrary.duotone(.float(tone), .float(t)))
                .distortionEffect(ShaderLibrary.ripple(.float(wave), .float(t)), maxSampleOffset: .zero)
                .layerEffect(ShaderLibrary.glitch(.float(glitch * 40), .float(t)),
                             maxSampleOffset: CGSize(width: 60, height: 0))
            VStack(spacing: 8) {
                slider("双色调", tone) { tone = $0 }
                slider("水波幅度", wave) { wave = $0 }
                slider("故障错位", glitch) { glitch = $0 }
            }
            .padding(.horizontal, 24)
        }
        .padding(16)
        .frame(width: 720)
        .onAppear { driveTime() }
    }

    // 时间参数驱动：Timer 每 50ms 刷新一次 time（涟漪/错位的动画源）
    func driveTime() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            t = Date().timeIntervalSince1970
        }
    }

    func slider(_ label: String, _ value: Float, _ onChange: @escaping (Float) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 80, alignment: .leading)
            Slider(value: Binding(get: { value }, set: onChange), in: 0...1)
        }
    }
}

@main
struct ShaderApp: App {
    init() {
        // 脚本化验证：AUTO_QUIT=<秒> 到点自动退出（独立 GPU 自检在 shader_check 进程）
        if let s = ProcessInfo.processInfo.environment["AUTO_QUIT"], let t = Double(s), t > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
        }
    }
    var body: some Scene {
        WindowGroup { ContentView().frame(width: 720, height: 520) }
    }
}
