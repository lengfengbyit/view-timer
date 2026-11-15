import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var panel: PanelView!
    private let engine = TimerEngine()
    private let monitor = PlaybackEndMonitor()
    private var warningWindow: WarningWindow?
    private var config = TimerConfig()
    private var didShowPermissionAlert = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Settings.shared.launchCount += 1

        buildStatusItem()
        buildPopover()
        bindEngine()

        LogStore.shared.add("\(AppConfig.appName) v\(AppConfig.version) 启动", level: .info)
        if let bid = AppConfig.resolveClientBundleID() {
            LogStore.shared.add("已识别腾讯视频客户端：\(bid)", level: .ok)
        } else {
            LogStore.shared.add("未找到腾讯视频客户端（官网版）；浏览器等播放源仍可通过系统暂停停下", level: .warn)
        }
        // 只在「从没授权过」的首次启动申请一次；授权过又失效时不再打扰，改为静默提示
        ensureAccessibility(prompt: !Settings.shared.accessibilityWasGranted)
        refreshStatusTitle()

        // 开发自检：VT_OPEN_PANEL=1 时自动弹出面板，便于截图核对
        if ProcessInfo.processInfo.environment["VT_OPEN_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.togglePopover()
            }
        }

        // 开发自检：VT_AUTOWARN=snooze|proceed 自动走「进入提醒 → 点击按钮」全流程，排查崩溃
        if ProcessInfo.processInfo.environment["VT_AUTOWARN"] != nil {
            runAutoWarnTest()
        }
    }

    // MARK: - 菜单栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "timer", accessibilityDescription: AppConfig.appName)
        button.imagePosition = .imageLeft
        button.title = " " + AppConfig.displayName
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "\(AppConfig.displayName) · 点击打开设置"
    }

    private func refreshStatusTitle() {
        guard let button = statusItem.button else { return }
        let symbol: String
        let title: String
        switch engine.state {
        case .idle:
            symbol = "timer"
            title = " " + AppConfig.displayName
        case .running, .warning:
            symbol = "timer"
            title = " " + PanelView.format(engine.remaining)
        case .executing:
            symbol = "hourglass"
            title = " 执行中"
        case .done:
            symbol = "checkmark.circle"
            title = " 已完成"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: AppConfig.appName)
        button.title = title
    }

    @objc private func statusItemClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        if isRightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开面板", action: #selector(togglePopover), keyEquivalent: "").target = self
        menu.addItem(withTitle: "辅助功能设置…", action: #selector(openPrivacy), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出 \(AppConfig.displayName)", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // 只弹一次，之后仍走左键面板
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        panel.reload()
        resizePopover()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildPopover() {
        panel = PanelView()
        panel.onStart = { [weak self] cfg in self?.startTimer(config: cfg) }
        panel.onCancel = { [weak self] in self?.cancelTimer() }
        panel.onFireNow = { [weak self] in self?.engine.fireNow() }
        panel.onReset = { [weak self] in self?.resetToIdle() }
        panel.onFixPermission = { [weak self] in self?.requestPermissionFromUser() }
        panel.onQuit = { NSApp.terminate(nil) }
        panel.onLayoutHeightChanged = { [weak self] in self?.resizePopover() }

        let vc = NSViewController()
        vc.view = panel

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = vc
        resizePopover()
    }

    private func resizePopover() {
        guard let popover, let panel else { return }
        popover.contentSize = NSSize(width: PanelView.panelWidth, height: panel.fittingPanelHeight)
    }

    // MARK: - 状态机

    private func bindEngine() {
        engine.onTick = { [weak self] remain in
            self?.panel.updateCountdown(remain)
            self?.warningWindow?.update(secondsLeft: Int(ceil(remain)))
            self?.refreshStatusTitle()
        }
        engine.onWarning = { [weak self] in self?.showWarningWindow() }
        engine.onFire = { [weak self] in self?.executeStop() }
        engine.onStateChange = { [weak self] state in
            self?.panel.apply(state: state)
            self?.refreshStatusTitle()
        }
    }

    private func startTimer(config cfg: TimerConfig) {
        self.config = cfg
        LogStore.shared.clear()

        if !AppConfig.clientInstalled {
            LogStore.shared.add("未检测到腾讯视频客户端：腾讯视频渠道不可用，浏览器等仍可通过系统暂停停下", level: .warn)
        }
        if !SystemActions.isAccessibilityGranted {
            LogStore.shared.add("辅助功能未授权：到点将无法发送按键或锁屏", level: .warn)
            promptPermissionAlert()
        }

        LogStore.shared.add("定时开始 · \(cfg.minutes) 分钟 · 策略：\(cfg.strategy.title) · 锁屏：\(cfg.lockScreen ? "开" : "关")", level: .info)
        let extras = [
            cfg.quitClient ? "退出腾讯视频" : nil,
            cfg.closeBrowserTab ? "关闭浏览器标签页" : nil,
        ].compactMap { $0 }
        LogStore.shared.add(extras.isEmpty
            ? "到点附加动作：未勾选（只停止播放）"
            : "到点附加动作（勾选即执行）：\(extras.joined(separator: "、"))", level: .info)

        if cfg.strategy == .episode {
            startEpisodeMonitor(cfg: cfg)
        }

        engine.start(config: cfg)
        if popover.isShown { popover.performClose(nil) }
    }

    private func startEpisodeMonitor(cfg: TimerConfig) {
        let bid = AppConfig.resolveClientBundleID() ?? AppConfig.clientBundleIDs[0]
        monitor.start(bundleID: bid, maxWait: TimeInterval(cfg.maxWaitMinutes * 60)) { [weak self] reason in
            guard let self else { return }
            LogStore.shared.add("播放结束信号：\(reason.display)", level: .ok)
            self.engine.fireNow()
        }
        LogStore.shared.add("已启动「播完当前」监听：音频静默 2.5s 即判定本集结束；上限 \(cfg.maxWaitMinutes) 分钟", level: .info)
    }

    private func cancelTimer() {
        monitor.stop()
        engine.cancel()
        closeWarning()
        LogStore.shared.add("已取消计时", level: .warn)
        refreshStatusTitle()
    }

    private func resetToIdle() {
        monitor.stop()
        engine.backToIdle()
        closeWarning()
        LogStore.shared.add("已重置，可开始下一次", level: .info)
        refreshStatusTitle()
    }

    // MARK: - 执行

    private func showWarningWindow() {
        guard warningWindow == nil, config.fullScreenAlert else { return }
        var msg = "定时即将结束，将停止正在播放的视频"
        let extras = [
            config.quitClient ? "退出腾讯视频" : nil,
            config.closeBrowserTab ? "关闭浏览器标签页" : nil,
        ].compactMap { $0 }
        if !extras.isEmpty { msg += "，并" + extras.joined(separator: "、") }
        if config.lockScreen { msg += "，然后锁定屏幕" }
        msg += "。点「立即执行」可马上停，点「再看 5 分钟」可延后。"

        let warnSeconds = max(1, Int(config.warnBeforeSeconds.rounded()))
        let w = WarningWindow(message: msg, warnSeconds: warnSeconds)
        w.onProceed = { [weak self] in
            self?.warningWindow = nil
            self?.engine.fireNow()
        }
        w.onSnooze = { [weak self] in
            guard let self else { return }
            self.warningWindow = nil
            self.engine.snooze(minutes: 5)
            LogStore.shared.add("用户选择「再看 5 分钟」，计时重置", level: .info)
            if self.config.strategy == .episode {
                self.startEpisodeMonitor(cfg: self.config)
            }
        }
        // 先挂上引用再展示：onTick 每 0.2s 会同步倒计时
        warningWindow = w
        w.update(secondsLeft: Int(ceil(engine.remaining)))
        w.present()
        if config.soundAlert { SystemActions.playAlertSound() }
        LogStore.shared.add("已弹出全屏提醒，\(warnSeconds) 秒后自动执行", level: .warn)
    }

    private func closeWarning() {
        guard let w = warningWindow else { return }
        warningWindow = nil
        w.onProceed = nil
        w.onSnooze = nil
        // 和 WarningWindow 内部一致：只 orderOut，绝不 close（close 会导致过度释放）
        w.orderOut(nil)
    }

    // MARK: - 开发自检（仅 VT_AUTOWARN 环境变量触发，不影响正常使用）

    /// 复现「提前 20 秒提醒 → 点按钮」这条路径：
    /// 用 warnBeforeSeconds 把提醒提前到第一次 tick，跳过等待。
    private func runAutoWarnTest() {
        let clickMode = ProcessInfo.processInfo.environment["VT_AUTOCLICK"]
            ?? ProcessInfo.processInfo.environment["VT_AUTOWARN"] ?? "snooze"
        NSLog("[vt-test] 计划点击：\(clickMode)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            var cfg = TimerConfig()
            cfg.minutes = 1
            cfg.warnBeforeSeconds = 61     // 第一次 tick 立刻进入提醒
            cfg.lockScreen = false
            cfg.fullScreenAlert = true
            self.config = cfg
            NSLog("[vt-test] engine.start")
            self.engine.start(config: cfg)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                guard let self else { return }
                guard let w = self.warningWindow else {
                    NSLog("[vt-test] 警告窗口没有出现，state=\(self.engine.state.label)")
                    exit(7)
                }
                NSLog("[vt-test] 警告窗口已出现，state=\(self.engine.state.label) 倒计时=\(w.countdownText)")

                if clickMode == "countdown" {
                    for i in 1...5 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.8) { [weak self] in
                            NSLog("[vt-test] +\(Double(i) * 0.8)s 倒计时=\(self?.warningWindow?.countdownText ?? "窗口已关闭")")
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.6) { [weak self] in
                        self?.closeWarning()
                        NSLog("[vt-test] 倒计时验证结束")
                        exit(0)
                    }
                    return
                }

                if clickMode == "timeout" {
                    // 模拟「什么都不点、到点自动执行」：窗口仍然存在，走 closeWarning()
                    NSLog("[vt-test] 不点击，直接到点执行")
                    self.engine.fireNow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        NSLog("[vt-test] 超时路径存活，state=\(self?.engine.state.label ?? "?")")
                        exit(0)
                    }
                    return
                }

                let title = clickMode == "proceed" ? "立即执行" : "再看 5 分钟"
                guard let b = Self.findButton(in: w.contentView, title: title) else {
                    NSLog("[vt-test] 找不到按钮：\(title)")
                    exit(8)
                }
                NSLog("[vt-test] 点击「\(b.title)」")
                if let action = b.action { NSApp.sendAction(action, to: b.target, from: b) }
                NSLog("[vt-test] sendAction 已返回")

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                    NSLog("[vt-test] 点击后存活，state=\(self?.engine.state.label ?? "?")")
                    exit(0)
                }
            }
        }
    }

    private static func findButton(in view: NSView?, title: String) -> NSButton? {
        guard let view else { return nil }
        if let b = view as? NSButton, b.title == title { return b }
        for sub in view.subviews {
            if let found = findButton(in: sub, title: title) { return found }
        }
        return nil
    }

    private func executeStop() {
        closeWarning()
        monitor.stop()

        // 开发自检：VT_NOSTOP=1 时只走状态流转，不真的暂停视频/锁屏
        if ProcessInfo.processInfo.environment["VT_NOSTOP"] != nil {
            LogStore.shared.add("（自检模式：跳过真实停止动作）", level: .info)
            engine.markDone()
            return
        }

        let cfg = config
        let bid = AppConfig.resolveClientBundleID() ?? AppConfig.clientBundleIDs[0]
        LogStore.shared.add("到点，开始执行停止动作序列", level: .info)
        if popover.isShown { popover.performClose(nil) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            StopExecutor.shared.execute(
                bundleID: bid,
                lockScreen: cfg.lockScreen,
                quitClient: cfg.quitClient,
                closeBrowserTab: cfg.closeBrowserTab,
                log: { line in
                    let level: LogStore.Level = (line.contains("未") || line.contains("失败") || line.contains("跳过")) ? .warn : .info
                    DispatchQueue.main.async { LogStore.shared.add(line, level: level) }
                },
                completion: { result in
                    DispatchQueue.main.async {
                        let lockText = cfg.lockScreen ? (result.locked ? "成功" : "未确认") : "未启用"
                        let progressText = result.lostProgress ? " · ⚠️ 播放进度已丢失" : ""
                        LogStore.shared.add(
                            "结果：\(result.stopped ? "已停止" : "未确认停止") · 方式：\(result.method) · 锁屏：\(lockText)\(progressText)",
                            level: result.stopped ? .ok : .err
                        )
                        self?.engine.markDone()
                    }
                }
            )
        }
    }

    // MARK: - 权限

    /// 启动时的权限自检。**只读不弹框**：
    /// 以前这里调 `requestAccessibility()`，只要判定未授权就弹系统授权框，
    /// 于是「每次启动都要求给权限」，而权限其实早就给过了——
    /// 真正原因是 ad-hoc 签名下每次重新编译 cdhash 都变，TCC 认为换了 App，旧授权失效。
    /// 现在改成：启动时只在日志/菜单栏提示，等用户主动点「去授权」再申请。
    private func ensureAccessibility(prompt: Bool) {
        if SystemActions.isAccessibilityGranted {
            if !Settings.shared.accessibilityWasGranted {
                Settings.shared.accessibilityWasGranted = true
            }
            LogStore.shared.add("辅助功能权限正常", level: .ok)
            return
        }
        if Settings.shared.accessibilityWasGranted {
            LogStore.shared.add("辅助功能授权已失效（App 签名变化或被撤销）：去「隐私与安全性 → 辅助功能」把 \(AppConfig.displayName) 取消勾选再重新勾选即可", level: .warn)
        } else {
            LogStore.shared.add("辅助功能未授权：请在「隐私与安全性 → 辅助功能」勾选 \(AppConfig.displayName)", level: .warn)
        }
        if prompt { SystemActions.requestAccessibility() }
    }

    /// 用户主动点「去授权」时走这里
    private func requestPermissionFromUser() {
        if !SystemActions.isAccessibilityGranted {
            SystemActions.requestAccessibility()
        }
        SystemActions.openAccessibilitySettings()
    }

    private func promptPermissionAlert() {
        guard !didShowPermissionAlert else { return }
        didShowPermissionAlert = true
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要「辅助功能」权限"
        if Settings.shared.accessibilityWasGranted {
            alert.informativeText = "之前已经授权过，但当前 App 的签名变了，系统把旧授权作废了。\n\n去「系统设置 → 隐私与安全性 → 辅助功能」里，把 view-timer 的开关**关一下再打开**（或在列表里删掉重新添加），然后重开 App。"
        } else {
            alert.informativeText = "view-timer 需要发送暂停按键与锁屏快捷键。\n\n请在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 view-timer。"
        }
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn { requestPermissionFromUser() }
    }

    @objc private func openPrivacy() {
        SystemActions.openAccessibilitySettings()
    }

    @objc private func quit() {
        monitor.stop()
        NSApp.terminate(nil)
    }
}
