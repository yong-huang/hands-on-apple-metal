import Cocoa

// 入口包装：调用实验程序本体 turing.swift 中的 runTuring()。
// 环境变量 AUTO_QUIT=<秒>：窗口打开指定秒数后自动退出（脚本化验证用）；
// 未设置时窗口保持打开，直到手动关闭。
if let s = ProcessInfo.processInfo.environment["AUTO_QUIT"], let t = Double(s), t > 0 {
    DispatchQueue.main.asyncAfter(deadline: .now() + t) {
        NSApplication.shared.terminate(nil)
    }
}

runTuring()
