import AppKit

/// 全屏提醒窗口：提前 20 秒盖在所有窗口（含全屏播放）之上，
/// 给自己一个反应窗口：「立即执行」或「再看 5 分钟」。
final class WarningWindow: NSWindow {

    var onProceed: (() -> Void)?
    var onSnooze: (() -> Void)?

    private let descLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private var isDismissing = false

    init(message: String, warnSeconds: Int) {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        // 关键：NSWindow 默认 isReleasedWhenClosed = true，close() 会额外发一次 release。
        // 而 AppDelegate 里还有 strong 引用（warningWindow），回调里再置 nil 就成了
        // 过度释放 → 崩在 objc_release / objc_autoreleasePoolPop（已用僵尸对象实测确认）。
        // 关掉它，窗口生命周期完全交给 ARC。
        isReleasedWhenClosed = false

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        ignoresMouseEvents = false

        let container = DimView()
        container.frame = screen.frame
        container.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "即将停止播放")
        title.font = .systemFont(ofSize: 34, weight: .bold)
        title.textColor = .white
        title.alignment = .center

        countdownLabel.stringValue = "\(warnSeconds) 秒后自动执行"
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        countdownLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        countdownLabel.alignment = .center

        descLabel.stringValue = message
        descLabel.font = .systemFont(ofSize: 14)
        descLabel.textColor = NSColor.white.withAlphaComponent(0.78)
        descLabel.alignment = .center
        descLabel.maximumNumberOfLines = 3
        descLabel.lineBreakMode = .byWordWrapping

        let proceed = OverlayButton(title: "立即执行", isMain: true)
        proceed.target = self
        proceed.action = #selector(proceedTapped)

        let snooze = OverlayButton(title: "再看 5 分钟", isMain: false)
        snooze.target = self
        snooze.action = #selector(snoozeTapped)

        let buttons = NSStackView(views: [proceed, snooze])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.alignment = .centerY

        let stack = NSStackView(views: [title, countdownLabel, descLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 16
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(10, after: title)
        stack.setCustomSpacing(22, after: descLabel)

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            descLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])

        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 仅自检用：读取当前倒计时文本
    var countdownText: String { countdownLabel.stringValue }

    /// 由 AppDelegate 的 onTick 驱动，与实际执行时刻严格同步（误差 < 0.2s）
    func update(secondsLeft: Int) {
        let s = max(0, secondsLeft)
        let urgent = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.30, alpha: 1)
        if s > 0 {
            countdownLabel.stringValue = "\(s) 秒后自动执行"
            countdownLabel.textColor = s <= 5 ? urgent : NSColor.white.withAlphaComponent(0.92)
        } else {
            countdownLabel.stringValue = "正在执行…"
            countdownLabel.textColor = urgent
        }
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            snoozeTapped()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            proceedTapped()
            return
        }
        super.keyDown(with: event)
    }

    @objc private func proceedTapped() {
        dismiss(using: onProceed)
    }

    @objc private func snoozeTapped() {
        dismiss(using: onSnooze)
    }

    /// 关闭只做 orderOut（发 setHidden:），绝不调用 close()：close() 会牵动
    /// 窗口的释放语义，是之前「点按钮 App 直接退出」的根因。
    /// 顺序也很重要：先解绑回调，再隐藏，最后执行动作，避免回调里再操作本窗口。
    private func dismiss(using callback: (() -> Void)?) {
        guard !isDismissing else { return }
        isDismissing = true
        let cb = callback
        onProceed = nil
        onSnooze = nil
        orderOut(nil)
        cb?()
    }
}

private final class DimView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor(calibratedRed: 0.03, green: 0.05, blue: 0.09, alpha: 0.92).cgColor
    }
}

private final class OverlayButton: NSButton {
    private let isMain: Bool

    init(title: String, isMain: Bool) {
        self.isMain = isMain
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 38).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 132).isActive = true
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func applyStyle() {
        layer?.backgroundColor = (isMain ? NSColor.white : NSColor.white.withAlphaComponent(0.12)).cgColor
        layer?.borderColor = (isMain ? NSColor.white : NSColor.white.withAlphaComponent(0.35)).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: isMain ? NSColor(calibratedWhite: 0.08, alpha: 1) : NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: isMain ? .semibold : .regular),
        ])
    }
}
