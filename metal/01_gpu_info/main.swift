import Foundation

// 入口包装：调用实验程序本体 gpu_info.swift 中的 runGPUInfo()。
// 程序跑完自然退出，无需窗口。
setenv("APPINTENTS_DISABLE", "1", 1)   // 静音与本实验无关的系统级告警
runGPUInfo()
