import AppKit
import Carbon
import CoreGraphics
import ApplicationServices

// 所有系统级动作集中在此，便于 v2 复用与替换。
enum SystemActions {

    // MARK: - 键盘（需辅助功能权限）

    static func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(20_000)
        up?.post(tap: .cghidEventTap)
    }

    private static func postFlagsChanged(_ key: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    /// 腾讯视频官方快捷键：空格 = 播放/暂停
    static func postSpace() {
        postKey(CGKeyCode(kVK_Space))
    }

    /// 系统媒体键 NX_KEYTYPE_PLAY = 16。语义是 toggle，调用前必须确认仍处于播放态。
    static func postMediaPlayPause() {
        postMediaKey(16, down: true)
        postMediaKey(16, down: false)
    }

    private static func postMediaKey(_ key: Int32, down: Bool) {
        let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
        guard let e = NSEvent.otherEvent(with: .systemDefined,
                                         location: .zero,
                                         modifierFlags: NSEvent.ModifierFlags(rawValue: 0),
                                         timestamp: 0,
                                         windowNumber: 0,
                                         context: nil,
                                         subtype: 8,
                                         data1: data1,
                                         data2: -1),
              let cg = e.cgEvent else { return }
        cg.post(tap: .cghidEventTap)
    }

    // MARK: - 系统媒体（MediaRemote）

    private typealias MRSendCommandFn = @convention(c) (Int32, CFDictionary?) -> Bool

    /// `MRMediaRemoteSendCommand` 是私有符号，用 dlsym 动态解析，不 link 私有框架。
    private static let mrSendCommand: MRSendCommandFn? = {
        let candidates = [
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            "/System/Library/PrivateFrameworks/MediaRemote.framework/Versions/A/MediaRemote",
        ]
        for path in candidates {
            if let handle = dlopen(path, RTLD_NOW),
               let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
                return unsafeBitCast(sym, to: MRSendCommandFn.self)
            }
        }
        return nil
    }()

    /// 发送系统级「暂停」（`kMRPause = 1`）。**幂等**：目标已暂停时再发也没有副作用，
    /// 所以可以无条件调用，不必先判断在不在播——这是它比空格/媒体键（都是 toggle）最大的优势。
    ///
    /// 只对「注册了 Now Playing」的 App 生效：
    ///   ✅ Edge / Chrome 等 Chromium 浏览器（网页视频）、QuickTime、Music 等
    ///   ❌ 腾讯视频客户端（实测不注册，发了也没反应，必须回退到「激活 + 空格」）
    ///
    /// ⚠️ 异步 XPC：`SendCommand` 返回 true 只代表**请求入队**。
    /// 实测发完立刻退出进程 → 命令静默丢失；保持进程存活约 1 秒 → 正常送达。
    /// 所以这里必须 `usleep` 等一会儿，且调用方不能在主线程上卡太久（本函数约阻塞 1 秒）。
    @discardableResult
    static func sendSystemPause() -> Bool {
        guard let fn = mrSendCommand else { return false }
        let accepted = fn(1, nil)
        usleep(1_000_000)
        return accepted
    }

    // MARK: - 浏览器（标签页兜底）

    /// 常见浏览器 bundle id。
    /// 白名单而非「按类别猜」：宁可漏判（漏判只会退化成「不关标签」），
    /// 也不能误判——把文档类 App 当成浏览器发 ⌘W，会关掉用户正在编辑的窗口。
    private static let browserBundleIDs: Set<String> = [
        "com.microsoft.edgemac",        // Microsoft Edge
        "com.google.Chrome",            // Chrome
        "com.apple.Safari",             // Safari
        "org.mozilla.firefox",          // Firefox
        "company.thebrowser.Browser",   // Arc
        "com.brave.Browser",            // Brave
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "com.tencent.QQBrowser",        // QQ 浏览器
    ]

    /// 自检专用：`VT_ONLY_BROWSERS=com.apple.QuickTimePlayerX` 时，
    /// **只**把列出的 bundle id 当成浏览器，其余一律忽略。
    /// 用途是拿 QuickTime 这类「关窗口无损失」的 App 冒充浏览器验证链路，
    /// 同时把真实的 Edge/Chrome 完全排除在外，避免误关用户标签页。
    private static let onlyBrowserOverride: Set<String>? = {
        let raw = ProcessInfo.processInfo.environment["VT_ONLY_BROWSERS"] ?? ""
        let set = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        return set.isEmpty ? nil : set
    }()

    private static func isKnownBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        if let only = onlyBrowserOverride { return only.contains(bundleID) }
        return browserBundleIDs.contains(bundleID)
    }

    /// 当前运行中的浏览器（只认常规 App，Helper 子进程的 activationPolicy 是 prohibited）
    static func browsers() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && isKnownBrowser($0.bundleIdentifier)
        }
    }

    private static func executablePath(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE = 4 * MAXPATHLEN = 4096，Swift 里拿不到该宏，直接写死
        let capacity = 4096
        var buf = [UInt8](repeating: 0, count: capacity)
        let n = proc_pidpath(pid, &buf, UInt32(capacity))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// 把「正在出声的 pid」映射回浏览器主 App。
    ///
    /// 浏览器的音频输出一律挂在 Helper 子进程上（实测 Edge 是
    /// `Microsoft Edge Helper (Aperitif)`），拿 helper 的 pid 查不到浏览器身份，
    /// 只能按可执行路径前缀（`<Browser>.app/`）反推回主 App。
    static func browsersWithAudio(owners: Set<pid_t>) -> [NSRunningApplication] {
        let apps = browsers()
        guard !apps.isEmpty, !owners.isEmpty else { return [] }

        var result: [NSRunningApplication] = []
        var seen = Set<pid_t>()

        for pid in owners {
            // 情况 1：pid 本身就是浏览器主进程
            if let app = apps.first(where: { $0.processIdentifier == pid }) {
                if seen.insert(pid).inserted { result.append(app) }
                continue
            }
            // 情况 2：Helper 子进程，按路径前缀反推
            guard let path = executablePath(pid: pid) else { continue }
            for app in apps {
                guard let bundlePath = app.bundleURL?.path else { continue }
                if path.hasPrefix(bundlePath + "/"), seen.insert(app.processIdentifier).inserted {
                    result.append(app)
                }
            }
        }
        return result
    }

    /// ⌘W：关闭前台窗口的**当前标签页**（浏览器）/ 当前窗口（其它 App）。
    ///
    /// ⚠️ 不可逆：浏览器会丢掉该标签的页面状态与播放进度。
    /// ⚠️ 只作用于**前台**窗口，所以调用前必须确认焦点确实在目标浏览器上，
    ///    否则会关到别的窗口；也关不掉「视频在后台标签」的情况。
    static func postCloseTab() {
        postKey(CGKeyCode(kVK_ANSI_W), flags: [.maskCommand])
    }

    // MARK: - 锁屏

    /// 锁屏：Control + Command + Q（先发修饰键的 flagsChanged，再发 Q，最后释放修饰键）。
    /// 硬约束：锁屏本身不中断后台播放，必须在「已确认暂停」之后调用。
    /// 返回是否确认锁屏成功。
    @discardableResult
    static func lockScreen() -> Bool {
        if isScreenLocked() {
            NSLog("[view-timer] 屏幕已处于锁定状态，跳过")
            return true
        }

        let src = CGEventSource(stateID: .hidSystemState)
        postFlagsChanged(CGKeyCode(kVK_Control), flags: [.maskControl])
        postFlagsChanged(CGKeyCode(kVK_Command), flags: [.maskControl, .maskCommand])
        usleep(40_000)

        if let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: true) {
            down.flags = [.maskControl, .maskCommand]
            down.post(tap: .cghidEventTap)
        }
        usleep(30_000)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_Q), keyDown: false) {
            up.flags = [.maskControl, .maskCommand]
            up.post(tap: .cghidEventTap)
        }
        usleep(30_000)

        postFlagsChanged(CGKeyCode(kVK_Command), flags: [.maskControl])
        postFlagsChanged(CGKeyCode(kVK_Control), flags: [])

        for _ in 0..<12 {
            usleep(200_000)
            if isScreenLocked() { return true }
        }
        return false
    }

    /// 备用锁屏：走 System Events（首次会弹自动化授权）
    @discardableResult
    static func lockScreenViaAppleScript() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        for _ in 0..<10 {
            usleep(200_000)
            if isScreenLocked() { return true }
        }
        return false
    }

    /// 屏幕是否已锁定（CGSessionCopyCurrentDictionary，公开符号，用于验证锁屏结果）
    static func isScreenLocked() -> Bool {
        guard let fn = sessionDictionaryFn else { return false }
        guard let dict = fn()?.takeRetainedValue() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private typealias SessionDictionaryFn = @convention(c) () -> Unmanaged<CFDictionary>?

    private static let sessionDictionaryFn: SessionDictionaryFn? = {
        guard let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
              let sym = dlsym(h, "CGSessionCopyCurrentDictionary") else { return nil }
        return unsafeBitCast(sym, to: SessionDictionaryFn.self)
    }()

    /// 最后兜底：关显示器（若系统设置了「睡眠后立即要求密码」，效果等同锁屏）
    static func displaySleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    // MARK: - 应用控制

    static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static func isRunning(bundleID: String) -> Bool { runningApp(bundleID: bundleID) != nil }

    /// 当前运行中的腾讯视频客户端（可能同时存在多个版本/副本）。
    ///
    /// 「到点关闭腾讯视频」是**勾选即执行**的附加动作，不该依赖「它是不是在播」，
    /// 所以要按 bundle id 白名单 + 应用名兜底把实例全捞出来，而不是只看播放源那一个。
    static func runningClients() -> [NSRunningApplication] {
        let candidates = Set(AppConfig.clientBundleIDs)
        return NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular else { return false }
            if let bid = app.bundleIdentifier, candidates.contains(bid) { return true }
            // 官网客户端改过 bundle id，名字兜底保证老版本也能被关掉
            return app.localizedName?.contains("腾讯视频") == true
        }
    }

    static func activate(bundleID: String) {
        runningApp(bundleID: bundleID)?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    /// 激活并**等到它真的成为前台**再返回。
    /// 客户端常年待在全屏 Space 里时，切 Space 有动画，立刻发按键会打到别的窗口上
    /// （这是之前误判「空格无效」的根因）。
    @discardableResult
    static func activateAndWait(bundleID: String, timeout: TimeInterval = 4.0) -> Bool {
        guard let app = runningApp(bundleID: bundleID) else { return false }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }

        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                // 切 Space 动画结束后再多给一点余量
                usleep(350_000)
                return true
            }
            usleep(100_000)
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    static func terminate(bundleID: String) {
        runningApp(bundleID: bundleID)?.terminate()
    }

    // MARK: - 辅助功能（AX）

    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    /// 带系统弹窗的权限请求（首次启动用）
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for s in urls {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { return }
        }
    }

    /// 曾用于「在 AX 树里找暂停控件直接按」，2026-11 实测后**已移除**：
    /// 腾讯视频是自绘 UI，AX 树里没有播放/暂停控件，永远返回 false；
    /// 而且它无法安全判定成败——按下后音频要 8 秒才静默，
    /// 这段窗口里既不能算成功也不能算失败，贸然补发空格会把视频重新放起来。
    /// 若将来客户端真提供了 AX 播放控件，再按需加回，且必须配独立的成功判据。

    /// 读取客户端窗口标题（诊断用）
    static func windowTitles(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { w in
            var t: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success
                ? (t as? String) : nil
        }
    }

    // MARK: - 提示音

    static func playAlertSound() {
        NSSound.beep()
    }
}
