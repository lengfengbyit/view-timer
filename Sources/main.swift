import AppKit

// 入口：纯代码构建，不使用 storyboard / SwiftUI 生命周期。
// 用显式 main.swift 而非 @main，避免 Command Line Tools 环境下 @main 与
// -parse-as-library 的入口推断问题（原骨架就是卡在这一步）。
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// 开发自检：VT_TEST_TOGGLE=1 验证空格暂停是否真的生效
if DevSnapshot.runToggleTestIfRequested() { exit(0) }

// 开发自检：VT_AXDUMP=1 打印客户端 AX 树
if DevSnapshot.runAXDumpIfRequested() { exit(0) }

// 开发自检：VT_SELFTEST=1 跑状态机 + 停止执行器（不锁屏）
if DevSnapshot.runSelfTestIfRequested() { exit(0) }

// 开发自检：渲染面板截图后直接退出（见 DevSnapshot.swift）
if DevSnapshot.runIfRequested() {
    exit(0)
}

let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
