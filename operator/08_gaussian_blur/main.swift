import Foundation
import MetalPerformanceShaders
import MetalPerformanceShadersGraph

// 入口包装：调用实验程序本体 gaussian_blur.swift 中的 runGaussianBlur()
setenv("APPINTENTS_DISABLE", "1", 1)
runGaussianBlur()
