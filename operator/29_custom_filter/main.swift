import Foundation
import MetalPerformanceShaders

// 入口包装：调用实验程序本体 custom_filter.swift 中的 runCustomFilter()
setenv("APPINTENTS_DISABLE", "1", 1)
runCustomFilter()
