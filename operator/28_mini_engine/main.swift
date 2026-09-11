import Foundation
import MetalPerformanceShaders

// 入口包装：调用实验程序本体 mini_engine.swift 中的 runMiniEngine()
setenv("APPINTENTS_DISABLE", "1", 1)
runMiniEngine()
