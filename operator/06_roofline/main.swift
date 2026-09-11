import Foundation

// 入口包装：调用实验程序本体 roofline.swift 中的 runRoofline()
setenv("APPINTENTS_DISABLE", "1", 1)
runRoofline()
