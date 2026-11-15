import AppKit

/// 把动态 NSColor 按视图的 effectiveAppearance 解析成静态 RGB 色再取 cgColor。
///
/// 坑：直接写 `NSColor.textBackgroundColor.cgColor`，AppKit 会按「当前 drawing
/// appearance」解析；在事件回调（isOn 的 didSet、点击处理）里没有 drawing 上下文，
/// 会回落成浅色的白色。而 attributedTitle / textColor 里的动态色由控件绘制时
/// 按深色外观解析成白字 —— 于是深色模式下未选中项变成白底白字，数字直接消失。
/// 背景与文字必须走同一套解析，这里统一处理。
private func resolved(_ color: NSColor, for view: NSView) -> NSColor {
    var out = color
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        out = color.usingColorSpace(.deviceRGB) ?? color
    }
    return out
}

// MARK: - 小控件

/// 圆角标签（状态徽章）
final class BadgeView: NSView {

    private let label = NSTextField(labelWithString: "")
    private var textColor: NSColor = .controlAccentColor
    private var fillColor: NSColor = NSColor.controlAccentColor.withAlphaComponent(0.12)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, color: NSColor) {
        label.stringValue = text
        textColor = color
        fillColor = color.withAlphaComponent(0.13)
        applyColors()
    }

    private func applyColors() {
        label.textColor = resolved(textColor, for: self)
        layer?.backgroundColor = resolved(fillColor, for: self).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}

/// 时长胶囊按钮
final class ChipButton: NSButton {

    var isOn: Bool = false { didSet { applyStyle() } }
    var onTap: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        setButtonType(.momentaryChange)
        target = self
        action = #selector(tapped)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onTap?() }

    func applyStyle() {
        let selected = isOn
        let bg: NSColor = selected ? .controlAccentColor : .textBackgroundColor
        let border: NSColor = selected ? .controlAccentColor : .separatorColor
        let fg: NSColor = selected ? .white : .labelColor
        layer?.backgroundColor = resolved(bg, for: self).cgColor
        layer?.borderColor = resolved(border, for: self).cgColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: resolved(fg, for: self),
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()   // 加入窗口后 effectiveAppearance 才最终确定
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

/// 策略卡片
final class OptionCard: NSView {

    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(wrappingLabelWithString: "")
    private let check = NSImageView()
    var isOn: Bool = false { didSet { applyStyle() } }
    var onTap: (() -> Void)?

    init(title: String, subtitle: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 1.5
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 64).isActive = true

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        subLabel.stringValue = subtitle
        subLabel.font = .systemFont(ofSize: 10.5)
        subLabel.textColor = .secondaryLabelColor
        subLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [titleLabel, subLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            subLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onTap?() }

    func applyStyle() {
        let bg: NSColor = isOn ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                               : .textBackgroundColor
        let border: NSColor = isOn ? .controlAccentColor : .separatorColor
        layer?.backgroundColor = resolved(bg, for: self).cgColor
        layer?.borderColor = resolved(border, for: self).cgColor
        titleLabel.textColor = resolved(isOn ? .controlAccentColor : .labelColor, for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

// MARK: - 面板

final class PanelView: NSView {

    var onStart: ((TimerConfig) -> Void)?
    var onCancel: (() -> Void)?
    var onFireNow: (() -> Void)?
    var onReset: (() -> Void)?
    var onFixPermission: (() -> Void)?
    var onQuit: (() -> Void)?
    var onLayoutHeightChanged: (() -> Void)?

    static let panelWidth: CGFloat = 360
    private static let inset: CGFloat = 18
    private static let contentWidth = panelWidth - inset * 2

    private let root = NSStackView()
    private let badge = BadgeView()
    private let setupStack = NSStackView()
    private let runningStack = NSStackView()

    private let countdownLabel = NSTextField(labelWithString: "--:--")
    private let countdownCaption = NSTextField(labelWithString: "距离停止播放")
    private let logDoc = LogDocumentView()
    private let logScroll = NSScrollView()
    private let logHeight: CGFloat = 138

    private let lockSwitch = NSSwitch()
    private let alertSwitch = NSSwitch()
    private let soundSwitch = NSSwitch()
    private let quitSwitch = NSSwitch()
    private let closeTabSwitch = NSSwitch()
    private let alertLeadField = NSTextField()
    private let epMinField = NSTextField()
    private let epMaxField = NSTextField()
    private let episodeBox = NSStackView()
    private let permissionLabel = NSTextField(labelWithString: "")

    private var chips: [ChipButton] = []
    private var cards: [OptionCard] = []
    private var chipGrid: NSStackView!
    private var presets: [Int] { Settings.shared.quickMinutes }
    private var selectedMinutes: Int = Settings.shared.minutes

    private var currentState: TimerState = .idle

    private var fireButton: NSButton!
    private var cancelButton: NSButton!
    private var resetButton: NSButton!

    // MARK: 初始化

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 460))
        wantsLayer = true
        build()
        refreshFromSettings()
        apply(state: .idle)
        updatePermissionLabel()
        LogStore.shared.onChange = { [weak self] in self?.reloadLog() }
        reloadLog()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.panelWidth),
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])

        let title = NSTextField(labelWithString: AppConfig.displayName)
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let header = NSStackView(views: [title, spacer, badge])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let subtitle = NSTextField(labelWithString: "v\(AppConfig.version) · 统一停止播放 · 到点暂停 / 锁屏")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let divider = NSBox()
        divider.boxType = .separator

        addFull(header)
        addFull(subtitle)
        addFull(divider)
        addFull(setupStack)
        addFull(runningStack)
        addFull(makeFooter())

        setupStack.orientation = .vertical
        setupStack.alignment = .leading
        setupStack.spacing = 7

        runningStack.orientation = .vertical
        runningStack.alignment = .leading
        runningStack.spacing = 10

        buildSetup()
        buildRunning()
    }

    /// 加入根栈并锁定到内容宽度（不依赖 stack 的自动对齐，避免溢出）
    private func addFull(_ v: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(v)
        v.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    private func fill(_ stack: NSStackView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
    }

    private func addRow(_ v: NSView, to stack: NSStackView, width: CGFloat = contentWidth, spacingAfter: CGFloat? = nil) {
        v.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        if let spacingAfter {
            stack.setCustomSpacing(spacingAfter, after: v)
        }
    }

    // MARK: 配置区

    private func buildSetup() {
        // 标题行：标题 + 右侧「编辑」，点开可改快捷时长
        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.addArrangedSubview(sectionTitle("定时时长（分钟）"))
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        titleRow.addArrangedSubview(titleSpacer)
        let editButton = NSButton(title: "编辑", target: self, action: #selector(editQuickMinutesTapped))
        editButton.isBordered = false
        editButton.font = .systemFont(ofSize: 11)
        editButton.contentTintColor = .secondaryLabelColor
        titleRow.addArrangedSubview(editButton)
        addRow(titleRow, to: setupStack, spacingAfter: 7)

        chipGrid = NSStackView()
        chipGrid.orientation = .vertical
        chipGrid.alignment = .leading
        chipGrid.spacing = 6
        addRow(chipGrid, to: setupStack, spacingAfter: 12)
        rebuildChips()

        addRow(sectionTitle("停止策略"), to: setupStack)

        let now = OptionCard(title: StopStrategy.now.title, subtitle: StopStrategy.now.subtitle)
        now.onTap = { [weak self] in self?.selectStrategy(.now) }
        let episode = OptionCard(title: StopStrategy.episode.title, subtitle: StopStrategy.episode.subtitle)
        episode.onTap = { [weak self] in self?.selectStrategy(.episode) }
        cards = [now, episode]

        let cardRow = NSStackView(views: cards)
        cardRow.orientation = .horizontal
        cardRow.alignment = .top
        cardRow.spacing = 8
        cardRow.distribution = .fillEqually
        addRow(cardRow, to: setupStack, spacingAfter: 12)

        // 播完当前：估算参数
        episodeBox.orientation = .vertical
        episodeBox.alignment = .leading
        episodeBox.spacing = 6
        episodeBox.wantsLayer = true
        episodeBox.layer?.cornerRadius = 8
        episodeBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
        episodeBox.edgeInsets = NSEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)

        let hint = NSTextField(wrappingLabelWithString:
            "v1 读不到客户端精确进度：检测到「播放停止」即触发；若等不到停止信号，到达上限也会执行。")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .secondaryLabelColor
        addRow(hint, to: episodeBox, width: Self.contentWidth - 20)

        configureNumberField(epMinField)
        configureNumberField(epMaxField)
        addRow(makeFieldRow(title: "本集剩余约", field: epMinField, unit: "分钟"),
               to: episodeBox, width: Self.contentWidth - 20)
        addRow(makeFieldRow(title: "最长等待上限", field: epMaxField, unit: "分钟"),
               to: episodeBox, width: Self.contentWidth - 20)

        addRow(episodeBox, to: setupStack, spacingAfter: 12)

        addRow(sectionTitle("到点后执行"), to: setupStack)
        addRow(makeStaticRow(text: "停止播放", value: "始终执行", valueColor: .systemGreen), to: setupStack)
        addRow(makeSwitchRow(title: "锁定屏幕", toggle: lockSwitch), to: setupStack)
        addRow(makeLeadSwitchRow(title: "全屏提醒", field: alertLeadField,
                                 toggle: alertSwitch), to: setupStack)
        addRow(makeSwitchRow(title: "停止前提示音", toggle: soundSwitch), to: setupStack, spacingAfter: 6)

        let extraHint = NSTextField(wrappingLabelWithString:
            "以下两项勾选即执行：到点除暂停播放外，还会退出腾讯视频 / 关闭浏览器前台标签。会丢播放进度与页面状态，浏览器会被切到前台。")
        extraHint.font = .systemFont(ofSize: 10.5)
        extraHint.textColor = .secondaryLabelColor
        addRow(extraHint, to: setupStack, width: Self.contentWidth, spacingAfter: 4)
        addRow(makeSwitchRow(title: "关闭腾讯视频（退出 App）", toggle: quitSwitch), to: setupStack)
        addRow(makeSwitchRow(title: "关闭浏览器标签页（⌘W）", toggle: closeTabSwitch),
               to: setupStack, spacingAfter: 14)

        let start = makeButton(title: "开始计时", style: .primary)
        start.target = self
        start.action = #selector(startTapped)
        addRow(start, to: setupStack)

        for sw in [lockSwitch, alertSwitch, soundSwitch, quitSwitch, closeTabSwitch] {
            sw.target = self
            sw.action = #selector(toggleChanged)
        }
    }

    // MARK: 运行区

    private func buildRunning() {
        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 40, weight: .bold)
        countdownLabel.alignment = .center
        countdownLabel.maximumNumberOfLines = 1
        countdownCaption.font = .systemFont(ofSize: 11)
        countdownCaption.textColor = .secondaryLabelColor
        countdownCaption.alignment = .center
        countdownCaption.maximumNumberOfLines = 2

        addRow(countdownLabel, to: runningStack, spacingAfter: 2)
        addRow(countdownCaption, to: runningStack, spacingAfter: 10)

        let logWidth = Self.contentWidth
        logDoc.frame = NSRect(x: 0, y: 0, width: logWidth, height: logHeight)
        logScroll.documentView = logDoc
        logScroll.hasVerticalScroller = true
        logScroll.scrollerStyle = .overlay
        logScroll.autohidesScrollers = true
        logScroll.drawsBackground = true
        logScroll.backgroundColor = NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1)
        logScroll.wantsLayer = true
        logScroll.layer?.cornerRadius = 8
        logScroll.layer?.masksToBounds = true
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.heightAnchor.constraint(equalToConstant: logHeight).isActive = true
        addRow(logScroll, to: runningStack)

        let fire = makeButton(title: "立即执行", style: .primary)
        fire.target = self
        fire.action = #selector(fireNowTapped)
        addRow(fire, to: runningStack)
        fireButton = fire

        let cancel = makeButton(title: "取消计时", style: .ghost)
        cancel.target = self
        cancel.action = #selector(cancelTapped)
        addRow(cancel, to: runningStack)
        cancelButton = cancel

        let reset = makeButton(title: "重新开始", style: .primary)
        reset.target = self
        reset.action = #selector(resetTapped)
        reset.isHidden = true
        addRow(reset, to: runningStack)
        resetButton = reset
    }

    private func makeFooter() -> NSView {
        permissionLabel.font = .systemFont(ofSize: 10.5)
        permissionLabel.textColor = .secondaryLabelColor
        permissionLabel.lineBreakMode = .byTruncatingTail

        let fix = NSButton(title: "权限", target: self, action: #selector(fixPermission))
        fix.isBordered = false
        fix.font = .systemFont(ofSize: 10.5)
        fix.contentTintColor = .controlAccentColor

        let quit = NSButton(title: "退出", target: self, action: #selector(quitTapped))
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 10.5)
        quit.contentTintColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let footer = NSStackView(views: [permissionLabel, spacer, fix, quit])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        return footer
    }

    // MARK: 状态刷新

    func apply(state: TimerState) {
        currentState = state
        switch state {
        case .idle:
            setBadge(text: "空闲", color: .secondaryLabelColor)
            showSetup(true)
        case .running:
            setBadge(text: "计时中", color: .systemGreen)
            showSetup(false)
            setRunningButtons(fire: true, cancel: true, reset: false)
            countdownCaption.stringValue = Settings.shared.strategy == .episode
                ? "等待本集结束 · 估算倒计时" : "距离停止播放"
        case .warning:
            setBadge(text: "即将执行", color: .systemOrange)
            showSetup(false)
            setRunningButtons(fire: true, cancel: true, reset: false)
            countdownCaption.stringValue = "即将停止播放，可点「立即执行」或稍等"
        case .executing:
            setBadge(text: "执行中", color: .systemOrange)
            showSetup(false)
            setRunningButtons(fire: false, cancel: false, reset: false)
            countdownLabel.stringValue = "00:00"
            countdownCaption.stringValue = "正在执行停止流程"
        case .done:
            setBadge(text: "已完成", color: .systemBlue)
            showSetup(false)
            setRunningButtons(fire: false, cancel: false, reset: true)
            countdownLabel.stringValue = "00:00"
            countdownCaption.stringValue = "本次定时已完成，点「重新开始」再来一次"
        }
        updatePermissionLabel()
        requestHeightUpdate()
    }

    private func setRunningButtons(fire: Bool, cancel: Bool, reset: Bool) {
        fireButton?.isHidden = !fire
        cancelButton?.isHidden = !cancel
        resetButton?.isHidden = !reset
    }

    func updateCountdown(_ remaining: TimeInterval) {
        countdownLabel.stringValue = Self.format(remaining)
    }

    func updatePermissionLabel() {
        let ax = SystemActions.isAccessibilityGranted
        let client = AppConfig.clientInstalled
        let parts = [ax ? "辅助功能 已授权" : "辅助功能 未授权",
                     client ? "腾讯视频 已安装" : "腾讯视频 未找到（浏览器仍可停）"]
        permissionLabel.stringValue = parts.joined(separator: " · ")
        // 腾讯视频缺失不再算错误：浏览器等渠道靠系统暂停即可，不需要它
        permissionLabel.textColor = ax ? .secondaryLabelColor : .systemOrange
    }

    private func showSetup(_ show: Bool) {
        setupStack.isHidden = !show
        runningStack.isHidden = show
        requestHeightUpdate()
    }

    func requestHeightUpdate() {
        layoutSubtreeIfNeeded()
        onLayoutHeightChanged?()
    }

    /// 面板每次弹出前刷新：设置、权限状态、日志
    func reload() {
        refreshFromSettings()
        updatePermissionLabel()
        reloadLog()
        apply(state: currentState)
        requestHeightUpdate()
    }

    var fittingPanelHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return max(root.fittingSize.height + 30, 200)
    }

    private func setBadge(text: String, color: NSColor) {
        badge.set(text: text, color: color)
    }

    // MARK: 交互

    private func refreshFromSettings() {
        let s = Settings.shared
        selectedMinutes = s.minutes
        updateChipSelection()
        lockSwitch.state = s.lockScreen ? .on : .off
        alertSwitch.state = s.fullScreenAlert ? .on : .off
        alertLeadField.stringValue = "\(s.warnBeforeSeconds)"
        alertLeadField.isEnabled = s.fullScreenAlert
        soundSwitch.state = s.soundAlert ? .on : .off
        quitSwitch.state = s.quitClient ? .on : .off
        closeTabSwitch.state = s.closeBrowserTab ? .on : .off
        epMinField.stringValue = "\(s.episodeRemainingMinutes)"
        epMaxField.stringValue = "\(s.maxWaitMinutes)"
        applyStrategyVisual(s.strategy)
    }

    /// 按当前快捷时长重建胶囊网格（4 列，最后一格固定为「自定义」）
    private func rebuildChips() {
        guard let grid = chipGrid else { return }
        for v in grid.arrangedSubviews {
            grid.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        chips.removeAll()

        let values = presets
        let columns = 4
        let cells = values.count + 1                      // + 自定义
        let rows = max(1, Int(ceil(Double(cells) / Double(columns))))

        var index = 0
        for _ in 0..<rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            row.distribution = .fillEqually

            for _ in 0..<columns {
                if index < values.count {
                    let m = values[index]
                    let chip = ChipButton(title: "\(m)")
                    chip.onTap = { [weak self] in self?.selectMinutes(m) }
                    chips.append(chip)
                    row.addArrangedSubview(chip)
                } else if index == values.count {
                    let custom = ChipButton(title: "自定义")
                    custom.onTap = { [weak self] in self?.promptCustomMinutes() }
                    chips.append(custom)
                    row.addArrangedSubview(custom)
                } else {
                    row.addArrangedSubview(NSView())      // 占位，保持等宽
                }
                index += 1
            }
            row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            grid.addArrangedSubview(row)
        }
        updateChipSelection()
    }

    private func updateChipSelection() {
        let values = presets
        for (i, chip) in chips.enumerated() where i < values.count {
            chip.isOn = values[i] == selectedMinutes
        }
        guard let custom = chips.last else { return }
        let isCustom = !values.contains(selectedMinutes)
        custom.isOn = isCustom
        let wanted = isCustom ? "自定义 \(selectedMinutes)" : "自定义"
        if custom.title != wanted {
            custom.title = wanted
            custom.applyStyle()
        }
    }

    @objc private func editQuickMinutesTapped() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "设置快捷时长"
        alert.informativeText = "用逗号分隔分钟数，如 5,10,15,20,30,60,90（1–600，最多 12 个；留空恢复默认）"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 270, height: 24))
        field.stringValue = presets.map(String.init).joined(separator: ",")
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let parsed = field.stringValue
            .split(whereSeparator: { " ,，、;；/".contains($0) })
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        Settings.shared.quickMinutes = parsed
        rebuildChips()
        requestHeightUpdate()
    }

    private func selectMinutes(_ m: Int) {
        selectedMinutes = m
        Settings.shared.minutes = m
        updateChipSelection()
    }

    private func promptCustomMinutes() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "自定义定时"
        alert.informativeText = "输入分钟数（1–600）"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        field.stringValue = "\(selectedMinutes)"
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            if let n = Int(field.stringValue), n >= 1, n <= 600 {
                selectMinutes(n)
            }
        }
    }

    private func selectStrategy(_ s: StopStrategy) {
        Settings.shared.strategy = s
        applyStrategyVisual(s)
        requestHeightUpdate()
    }

    private func applyStrategyVisual(_ s: StopStrategy) {
        cards[safe: 0]?.isOn = (s == .now)
        cards[safe: 1]?.isOn = (s == .episode)
        episodeBox.isHidden = (s != .episode)
    }

    @objc private func toggleChanged() {
        let s = Settings.shared
        s.lockScreen = lockSwitch.state == .on
        s.fullScreenAlert = alertSwitch.state == .on
        alertLeadField.isEnabled = s.fullScreenAlert
        s.soundAlert = soundSwitch.state == .on
        s.quitClient = quitSwitch.state == .on
        s.closeBrowserTab = closeTabSwitch.state == .on
    }

    @objc private func alertLeadChanged() {
        if let n = Int(alertLeadField.stringValue), n >= 3, n <= 120 {
            Settings.shared.warnBeforeSeconds = n
        }
        // 无论合法与否都回写一次，避免输入框停在非法值上
        alertLeadField.stringValue = "\(Settings.shared.warnBeforeSeconds)"
    }

    @objc private func startTapped() {
        let s = Settings.shared
        s.minutes = selectedMinutes
        readEpisodeFields()
        alertLeadChanged()          // 用户可能改完秒数直接点开始，没按回车

        var config = TimerConfig()
        config.minutes = selectedMinutes
        config.strategy = s.strategy
        config.lockScreen = s.lockScreen
        config.fullScreenAlert = s.fullScreenAlert
        config.warnBeforeSeconds = TimeInterval(s.warnBeforeSeconds)
        config.soundAlert = s.soundAlert
        config.quitClient = s.quitClient
        config.closeBrowserTab = s.closeBrowserTab
        config.episodeRemainingMinutes = s.episodeRemainingMinutes
        config.maxWaitMinutes = s.maxWaitMinutes
        onStart?(config)
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func fireNowTapped() { onFireNow?() }
    @objc private func resetTapped() { onReset?() }
    @objc private func fixPermission() { onFixPermission?() }
    @objc private func quitTapped() { onQuit?() }
    @objc private func episodeFieldsChanged() { readEpisodeFields() }

    private func readEpisodeFields() {
        if let n = Int(epMinField.stringValue), n >= 1, n <= 300 {
            Settings.shared.episodeRemainingMinutes = n
        } else {
            epMinField.stringValue = "\(Settings.shared.episodeRemainingMinutes)"
        }
        if let n = Int(epMaxField.stringValue), n >= 1, n <= 600 {
            Settings.shared.maxWaitMinutes = n
        } else {
            epMaxField.stringValue = "\(Settings.shared.maxWaitMinutes)"
        }
    }

    // MARK: 日志

    private func reloadLog() {
        let text = NSMutableAttributedString()
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let mono = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byCharWrapping
        para.alignment = .left

        for line in LogStore.shared.lines {
            let color: NSColor
            switch line.level {
            case .info: color = NSColor(calibratedRed: 0.62, green: 0.72, blue: 0.88, alpha: 1)
            case .ok: color = NSColor(calibratedRed: 0.43, green: 0.90, blue: 0.66, alpha: 1)
            case .warn: color = NSColor(calibratedRed: 0.99, green: 0.83, blue: 0.30, alpha: 1)
            case .err: color = NSColor(calibratedRed: 0.99, green: 0.65, blue: 0.65, alpha: 1)
            }
            text.append(NSAttributedString(string: "[\(fmt.string(from: line.time))] ", attributes: [
                .font: mono,
                .foregroundColor: NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.53, alpha: 1),
                .paragraphStyle: para,
            ]))
            text.append(NSAttributedString(string: line.text + "\n", attributes: [
                .font: mono, .foregroundColor: color, .paragraphStyle: para,
            ]))
        }

        logDoc.attributed = text
        logDoc.textWidth = Self.contentWidth - 26
        logDoc.relayout()
        // 滚到底部（最新一条）
        let overflow = max(0, logDoc.frame.height - logHeight)
        logScroll.contentView.scroll(to: NSPoint(x: 0, y: overflow))
        logScroll.reflectScrolledClipView(logScroll.contentView)
    }

    // MARK: 构造辅助

    private func sectionTitle(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func makeSwitchRow(title: String, toggle: NSSwitch) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 12.5)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [l, spacer, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return row
    }

    /// 「全屏提醒  …  提前 [10] 秒  [开关]」这种带数值的行
    private func makeLeadSwitchRow(title: String, field: NSTextField, toggle: NSSwitch) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 12.5)
        let prefix = NSTextField(labelWithString: "提前")
        prefix.font = .systemFont(ofSize: 11)
        prefix.textColor = .secondaryLabelColor
        let suffix = NSTextField(labelWithString: "秒")
        suffix.font = .systemFont(ofSize: 11)
        suffix.textColor = .secondaryLabelColor

        field.translatesAutoresizingMaskIntoConstraints = false
        field.alignment = .center
        field.font = .systemFont(ofSize: 11.5)
        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.minimum = 3
        fmt.maximum = 120
        field.formatter = fmt
        field.target = self
        field.action = #selector(alertLeadChanged)
        field.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [l, spacer, prefix, field, suffix, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return row
    }

    private func makeStaticRow(text: String, value: String, valueColor: NSColor) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12.5)
        let v = NSTextField(labelWithString: value)
        v.font = .systemFont(ofSize: 11, weight: .semibold)
        v.textColor = valueColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [l, spacer, v])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return row
    }

    private func configureNumberField(_ f: NSTextField) {
        f.translatesAutoresizingMaskIntoConstraints = false
        f.alignment = .center
        f.font = .systemFont(ofSize: 12)
        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.minimum = 1
        fmt.maximum = 600
        f.formatter = fmt
        f.target = self
        f.action = #selector(episodeFieldsChanged)
        f.widthAnchor.constraint(equalToConstant: 54).isActive = true
    }

    private func makeFieldRow(title: String, field: NSTextField, unit: String) -> NSView {
        let l = NSTextField(labelWithString: title)
        l.font = .systemFont(ofSize: 11.5)
        let u = NSTextField(labelWithString: unit)
        u.font = .systemFont(ofSize: 11)
        u.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [l, spacer, field, u])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private enum ButtonStyle { case primary, ghost }

    private func makeButton(title: String, style: ButtonStyle) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 9
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        b.layer?.backgroundColor = (style == .primary
            ? NSColor.controlAccentColor
            : NSColor.controlAccentColor.withAlphaComponent(0.10)).cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: style == .primary ? NSColor.white : NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
        return b
    }

    static func format(_ seconds: TimeInterval) -> String {
        let v = max(0, Int(seconds.rounded(.up)))
        if v >= 3600 {
            return String(format: "%d:%02d:%02d", v / 3600, (v % 3600) / 60, v % 60)
        }
        return String(format: "%02d:%02d", v / 60, v % 60)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}


/// 自绘日志视图：故意不用 NSTextView —— 在 popover 的窄宽度下它会自行变宽，
/// 导致文本被裁切。直接 draw 富文本 + 显式宽度最省事也最可控。
final class LogDocumentView: NSView {

    var attributed: NSAttributedString?
    var textWidth: CGFloat = 306

    private let inset = NSSize(width: 9, height: 8)

    override var isFlipped: Bool { true }

    func relayout() {
        guard let attributed else {
            frame.size.height = 132
            needsDisplay = true
            return
        }
        let rect = attributed.boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let h = max(rect.height + inset.height * 2, 132)
        frame.size = NSSize(width: textWidth + inset.width * 2, height: h)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let attributed else { return }
        let area = NSRect(x: inset.width,
                          y: inset.height,
                          width: textWidth,
                          height: max(0, bounds.height - inset.height * 2))
        attributed.draw(with: area, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}
