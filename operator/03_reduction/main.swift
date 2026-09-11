import Foundation

// 入口包装：调用实验程序本体 reduction.swift 中的 runReduction()
setenv("APPINTENTS_DISABLE", "1", 1)
runReduction()
