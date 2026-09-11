import Foundation

// 入口包装：调用实验程序本体 matmul_naive.swift 中的 runMatmulNaive()
setenv("APPINTENTS_DISABLE", "1", 1)
runMatmulNaive()
