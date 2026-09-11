import Foundation
import MetalPerformanceShaders

// 入口包装：调用实验程序本体 sobel.swift 中的 runSobel()
setenv("APPINTENTS_DISABLE", "1", 1)
runSobel()
