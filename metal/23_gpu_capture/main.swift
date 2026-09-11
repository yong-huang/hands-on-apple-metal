import Foundation

// 入口包装：调用实验程序本体 gpu_capture.swift 中的 runGpuCapture()
// 程序跑完自然退出，无需窗口。
setenv("APPINTENTS_DISABLE", "1", 1)
runGpuCapture()
