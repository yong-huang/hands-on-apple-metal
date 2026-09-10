import Foundation

// 入口包装：调用实验程序本体 command_queue.swift 中的 runCommandQueue()。
// 程序跑完自然退出，无需窗口。
setenv("APPINTENTS_DISABLE", "1", 1)   // 静音与本实验无关的系统级告警
runCommandQueue()
