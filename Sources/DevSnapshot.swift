import AppKit

/// 开发用：把面板渲染成 PNG，便于在没有辅助功能/自动化权限时做视觉自检。
/// 用法： VT_SNAPSHOT=/tmp/panel.png VT_SNAPSHOT_STATE=running ./view-timer
/// 正常启动不受影响。
enum DevSnapshot {

    // MARK: - 端到端自检（不锁屏、不弹全屏，仅验证状态机与停止执行器）

    static func runSelfTestIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["VT_SELFTEST"] != nil else { return false }

        print("=== 1. 环境 ===")
        print("client bundle id : \(AppConfig.resolveClientBundleID() ?? "未找到")")
        print("辅助功能         : \(SystemActions.isAccessibilityGranted)")
        if let bid = AppConfig.resolveClientBundleID(),
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            let playing = AudioActivity.shared.isOutputActive(pid: app.processIdentifier)
            print("客户端 pid       : \(app.processIdentifier)  音频输出=\(playing)")
        }

        print("=== 2. TimerEngine 状态机 ===")
        let engine = TimerEngine()
        engine.onStateChange = { print("state -> \($0.label)") }
        engine.onWarning = { print("onWarning（全屏提醒时机）") }
        engine.onFire = { print("onFire（到点执行）") }
        var cfg = TimerConfig()
        cfg.minutes = 10
        cfg.fullScreenAlert = true
        cfg.warnBeforeSeconds = 1.2
        engine.start(config: cfg)
        print("start: state=\(engine.state.label) remain=\(Int(engine.remaining))s")
        engine.snooze(minutes: 1)
        print("snooze(1min): remain=\(Int(engine.remaining))s")
        engine.fireNow()
        print("fireNow: state=\(engine.state.label)")
        engine.markDone()
        print("markDone: state=\(engine.state.label)")

        print("=== 3. StopExecutor 真跑（lockScreen=false）===")
        // 没装腾讯视频也继续跑：关标签这条附加动作不依赖客户端
        let bid = AppConfig.resolveClientBundleID() ?? AppConfig.clientBundleIDs[0]
        if AppConfig.resolveClientBundleID() == nil { print("未安装腾讯视频，仅验证浏览器通道") }
        // VT_CLOSETAB=1 真发 ⌘W；=drill 只演练（识别+激活，不按键）
        let raw = ProcessInfo.processInfo.environment["VT_CLOSETAB"] ?? ""
        let closeTab = (raw == "1" || raw == "drill")
        print("closeBrowserTab = \(closeTab)\(raw == "drill" ? "（演练，不按键）" : "")")
        // VT_QUITCLIENT=1 真退出；=drill 只演练（不退出）
        let quitRaw = ProcessInfo.processInfo.environment["VT_QUITCLIENT"] ?? ""
        let quitClient = (quitRaw == "1" || quitRaw == "drill")
        print("quitClient = \(quitClient)\(quitRaw == "drill" ? "（演练，不退出）" : "")")
        StopExecutor.shared.execute(bundleID: bid, lockScreen: false, quitClient: quitClient,
                                    closeBrowserTab: closeTab,
                                    log: { print("  · \($0)") }) { result in
            print("RESULT stopped=\(result.stopped) method=\(result.method) locked=\(result.locked)")
            print("NOTES  \(result.notes)")
            exit(result.stopped ? 0 : 2)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(40))
        print("超时未返回")
        exit(3)
    }

    /// VT_AXDUMP=1：把腾讯视频的 AX 树里所有带标题的控件打出来，判断能否靠 AX 读播放状态
    static func runAXDumpIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["VT_AXDUMP"] != nil else { return false }
        print("accessibility granted = \(SystemActions.isAccessibilityGranted)")
        guard let bid = AppConfig.resolveClientBundleID(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else {
            print("客户端未运行"); return true
        }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var visited = 0
        func copy(_ n: AXUIElement, _ a: CFString) -> String? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(n, a, &v) == .success ? (v as? String) : nil
        }
        func walk(_ n: AXUIElement, _ d: Int) {
            if d > 16 || visited > 6000 { return }
            visited += 1
            let role = copy(n, kAXRoleAttribute as CFString) ?? ""
            let title = copy(n, kAXTitleAttribute as CFString) ?? ""
            let desc = copy(n, kAXDescriptionAttribute as CFString) ?? ""
            let value = copy(n, kAXValueAttribute as CFString) ?? ""
            let help = copy(n, kAXHelpAttribute as CFString) ?? ""
            let hay = "\(title) \(desc) \(value) \(help)"
            if !hay.trimmingCharacters(in: .whitespaces).isEmpty {
                print("[\(d)] \(role) | t=\(title) | d=\(desc) | v=\(value) | h=\(help)")
            }
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(n, kAXChildrenAttribute as CFString, &v) == .success,
               let arr = v as? [AXUIElement] { for c in arr { walk(c, d + 1) } }
        }
        walk(ax, 0)
        print("visited=\(visited)")
        return true
    }

    /// VT_TEST_TOGGLE=1：真实验证「激活客户端 + 空格」是否能暂停（会发出一次空格，随后再发一次还原）
    static func runToggleTestIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["VT_TEST_TOGGLE"] != nil else { return false }
        guard let bid = AppConfig.resolveClientBundleID(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first else {
            print("客户端未运行"); return true
        }
        let pid = app.processIdentifier
        let mode = ProcessInfo.processInfo.environment["VT_TEST_KEYS"] ?? "space"

        func snap(_ label: String) {
            let a = AudioActivity.shared.isOutputActive(pid: pid)
            let c = ProcessActivity.cpuPercent(pid: pid, window: 1.2) ?? -1
            print(String(format: "%@ audio=%@ cpu=%5.1f%%", label, a ? "1" : "0", c))
        }

        print("辅助功能 = \(SystemActions.isAccessibilityGranted)")
        print("前台(前) = \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
        snap("BEFORE ")

        switch mode {
        case "space", "both":
            let ok = SystemActions.activateAndWait(bundleID: bid)
            print("激活并确认前台 = \(ok) → \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
            SystemActions.postSpace()
            usleep(1_200_000)
            snap("SPACE  ")
        case "media":
            SystemActions.postMediaPlayPause()
            usleep(1_200_000)
            snap("MEDIA  ")
        default:
            break
        }
        return true
    }

    static func runIfRequested() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let overlayPath = env["VT_SNAPSHOT_OVERLAY"], !overlayPath.isEmpty {
            NSApp.appearance = NSAppearance(named: .aqua)
            let w = WarningWindow(message: "定时即将结束，将暂停腾讯视频并锁定屏幕。点「立即执行」可马上停，点「再看 5 分钟」可延后。",
                                  warnSeconds: 10)
            w.setFrame(NSRect(x: 0, y: 0, width: 640, height: 420), display: true)
            w.contentView?.layoutSubtreeIfNeeded()
            if let host = w.contentView, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: overlayPath))
                }
            }
            return true
        }
        guard let path = env["VT_SNAPSHOT"], !path.isEmpty else { return false }

        let state = env["VT_SNAPSHOT_STATE"] ?? "idle"
        let dark = (env["VT_SNAPSHOT_APPEARANCE"] ?? "light") == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if (env["VT_SNAPSHOT_STRATEGY"] ?? "now") == "episode" {
            Settings.shared.strategy = .episode
        } else {
            Settings.shared.strategy = .now
        }

        let panel = PanelView()

        if state == "running" || state == "warning" || state == "done" {
            LogStore.shared.clear()
            LogStore.shared.add("定时开始 · 45 分钟 · 策略：到点立即停止 · 锁屏：开", level: .info)
            LogStore.shared.add("已识别腾讯视频客户端：com.tencent.tenvideo", level: .ok)
            LogStore.shared.add("辅助功能权限正常", level: .ok)
            LogStore.shared.add("第 1 级：AX 树里没有可用的暂停控件，跳过", level: .warn)
            LogStore.shared.add("第 2 级：已激活腾讯视频并发送空格键", level: .info)
            LogStore.shared.add("停止已确认，执行锁屏（Control+Command+Q）", level: .info)
            LogStore.shared.add("锁屏成功", level: .ok)
            panel.updateCountdown(state == "done" ? 0 : 12 * 60 + 34)
            switch state {
            case "warning": panel.apply(state: .warning)
            case "done": panel.apply(state: .done)
            default: panel.apply(state: .running)
            }
        } else {
            panel.apply(state: .idle)
        }

        let size = NSSize(width: PanelView.panelWidth, height: panel.fittingPanelHeight)
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        panel.frame = NSRect(origin: .zero, size: size)
        host.addSubview(panel)

        // 放进真实窗口：NSScrollView / NSTextView 需要窗口才会排版文本
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return true }
        window.displayIfNeeded()
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return true }
        try? data.write(to: URL(fileURLWithPath: path))
        NSLog("[view-timer] snapshot written: \(path) size=\(size)")
        return true
    }
}
