import Foundation
import MetalPerformanceShaders
import MetalPerformanceShadersGraph

// 入口包装：调用实验程序本体 mps_matmul.swift 中的 runMpsMatmul()
setenv("APPINTENTS_DISABLE", "1", 1)
runMpsMatmul()
