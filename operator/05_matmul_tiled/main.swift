import Foundation

// 入口包装：调用实验程序本体 matmul_tiled.swift 中的 runMatmulTiled()
setenv("APPINTENTS_DISABLE", "1", 1)
runMatmulTiled()
