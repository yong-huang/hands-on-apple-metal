import Foundation
import MetalPerformanceShaders
import MetalPerformanceShadersGraph

// 入口包装：调用实验程序本体 mpsgraph.swift 中的 runMpsgraph()
setenv("APPINTENTS_DISABLE", "1", 1)
runMpsgraph()
