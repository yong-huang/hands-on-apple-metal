import Foundation
import MetalPerformanceShaders

// 入口包装：调用实验程序本体 fused_gemm_act.swift 中的 runFusedGemmAct()
setenv("APPINTENTS_DISABLE", "1", 1)
runFusedGemmAct()
