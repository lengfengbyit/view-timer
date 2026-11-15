import Foundation
import AppKit

// MARK: - 全局配置

enum StopStrategy: String, CaseIterable {
    case now        // 到点立即停止
    case episode    // 播完当前再停（事件驱动 / 估算）

    var title: String {
        switch self {
        case .now: return "到点立即停止"
        case .episode: return "播完当前再停"
        }
    }

    var subtitle: String {
        switch self {
        case .now: return "时间一到马上暂停播放，最稳"
        case .episode: return "本集结束才停，音频静默判定"
        }
    }
}

enum AppConfig {

    static let appName = "view-timer"
    static let displayName = "view-timer"
    static let version = "1.2.0"
    static let buildNumber = "5"

    /// 腾讯视频 Mac 官网客户端的候选 bundle id。
    /// 本机实测：`osascript -e 'id of app "腾讯视频"'` → com.tencent.tenvideo（QQLive.app）
    static let clientBundleIDs: [String] = [
        "com.tencent.tenvideo",
        "com.tencent.qqlive",
        "com.tencent.tenvideo.mac",
    ]

    /// 解析当前机器上腾讯视频客户端的 bundle id（找不到返回 nil）
    static func resolveClientBundleID() -> String? {
        for id in clientBundleIDs where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            return id
        }
        // 兜底：按应用名匹配（改版改 id 时仍能工作）
        for app in NSWorkspace.shared.runningApplications {
            if let name = app.localizedName, name.contains("腾讯视频"), let bid = app.bundleIdentifier {
                return bid
            }
        }
        return nil
    }

    static var clientInstalled: Bool { resolveClientBundleID() != nil }
}

// MARK: - 设置持久化

final class Settings {

    static let shared = Settings()
    private let defaults = UserDefaults.standard
    private init() {}

    /// 默认快捷时长（分钟）
    static let defaultQuickMinutes = [5, 10, 15, 20, 30, 60, 90]

    private enum Key {
        static let minutes = "vt.minutes"
        static let quickMinutes = "vt.quickMinutes"
        static let strategy = "vt.strategy"
        static let lockScreen = "vt.lockScreen"
        static let fullScreenAlert = "vt.fullScreenAlert"
        static let warnBeforeSeconds = "vt.warnBeforeSeconds"
        static let soundAlert = "vt.soundAlert"
        // 沿用旧 key：用户已经勾过的开关不能因为改名被悄悄重置
        static let quitClient = "vt.terminateFallback"
        static let closeBrowserTab = "vt.closeBrowserTab"
        static let episodeRemaining = "vt.episodeRemaining"
        static let maxWait = "vt.maxWait"
        static let launchCount = "vt.launchCount"
        static let accessibilityWasGranted = "vt.axWasGranted"
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Key.minutes: 30,
            Key.quickMinutes: Settings.defaultQuickMinutes,
            Key.strategy: StopStrategy.now.rawValue,
            Key.lockScreen: true,
            Key.fullScreenAlert: true,
            Key.warnBeforeSeconds: 10,
            Key.soundAlert: false,
            Key.quitClient: false,
            Key.closeBrowserTab: false,
            Key.episodeRemaining: 35,
            Key.maxWait: 120,
        ])
    }

    var minutes: Int {
        get { registerDefaults(); return clamp(defaults.integer(forKey: Key.minutes), 1, 600) }
        set { defaults.set(clamp(newValue, 1, 600), forKey: Key.minutes) }
    }

    var strategy: StopStrategy {
        get { registerDefaults(); return StopStrategy(rawValue: defaults.string(forKey: Key.strategy) ?? "") ?? .now }
        set { defaults.set(newValue.rawValue, forKey: Key.strategy) }
    }

    /// 面板上的快捷时长（分钟），用户可自定义。去重、升序、限制 1–600、最多 12 个。
    var quickMinutes: [Int] {
        get {
            registerDefaults()
            // 注意：不能用 `array(forKey:) as? [Int]`——UserDefaults 存的是 NSNumber，
            // 整段条件转换并不可靠（实测会失败并静默回退默认值），必须逐元素解析。
            guard let raw = defaults.array(forKey: Key.quickMinutes), !raw.isEmpty else {
                return Settings.defaultQuickMinutes
            }
            let values = raw.compactMap { element -> Int? in
                if let n = element as? NSNumber { return n.intValue }
                if let i = element as? Int { return i }
                if let s = element as? String { return Int(s) }
                return nil
            }
            return Settings.sanitize(values)
        }
        set { defaults.set(Settings.sanitize(newValue), forKey: Key.quickMinutes) }
    }

    /// 规范化一组分钟数：夹紧到 1–600、去重、升序、截断到 12 个；全非法则回退默认值。
    private static func sanitize(_ values: [Int]) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for v in values {
            let c = min(max(v, 1), 600)
            if seen.insert(c).inserted { out.append(c) }
        }
        out.sort()
        if out.count > 12 { out = Array(out.prefix(12)) }
        return out.isEmpty ? Settings.defaultQuickMinutes : out
    }

    var lockScreen: Bool {
        get { registerDefaults(); return defaults.bool(forKey: Key.lockScreen) }
        set { defaults.set(newValue, forKey: Key.lockScreen) }
    }

    var fullScreenAlert: Bool {
        get { registerDefaults(); return defaults.bool(forKey: Key.fullScreenAlert) }
        set { defaults.set(newValue, forKey: Key.fullScreenAlert) }
    }

    /// 全屏提醒提前多少秒弹出（同时就是提醒窗口上的倒计时时长）
    var warnBeforeSeconds: Int {
        get { registerDefaults(); return clamp(defaults.integer(forKey: Key.warnBeforeSeconds), 3, 120) }
        set { defaults.set(clamp(newValue, 3, 120), forKey: Key.warnBeforeSeconds) }
    }

    var soundAlert: Bool {
        get { registerDefaults(); return defaults.bool(forKey: Key.soundAlert) }
        set { defaults.set(newValue, forKey: Key.soundAlert) }
    }

    /// 到点附加动作：**勾选即无条件退出腾讯视频**（不管它在不在播、暂停成功没成功）。
    /// 会丢播放进度，默认关闭；UserDefaults key 沿用 `vt.terminateFallback`。
    var quitClient: Bool {
        get { registerDefaults(); return defaults.bool(forKey: Key.quitClient) }
        set { defaults.set(newValue, forKey: Key.quitClient) }
    }

    /// 到点附加动作：**勾选即无条件关闭浏览器前台标签页**（⌘W）。
    /// 不再要求检测到音频、也不再要求浏览器本来就在前台——勾了就把运行中的浏览器
    /// 逐个激活再关标签。会切焦点、丢页面状态，默认关闭。
    var closeBrowserTab: Bool {
        get { registerDefaults(); return defaults.bool(forKey: Key.closeBrowserTab) }
        set { defaults.set(newValue, forKey: Key.closeBrowserTab) }
    }

    var episodeRemainingMinutes: Int {
        get { registerDefaults(); return clamp(defaults.integer(forKey: Key.episodeRemaining), 1, 300) }
        set { defaults.set(clamp(newValue, 1, 300), forKey: Key.episodeRemaining) }
    }

    var maxWaitMinutes: Int {
        get { registerDefaults(); return clamp(defaults.integer(forKey: Key.maxWait), 1, 600) }
        set { defaults.set(clamp(newValue, 1, 600), forKey: Key.maxWait) }
    }

    var launchCount: Int {
        get { defaults.integer(forKey: Key.launchCount) }
        set { defaults.set(newValue, forKey: Key.launchCount) }
    }

    /// 曾经成功拿到过辅助功能权限。
    /// 用来区分「从没授权过（首次引导）」和「授权过但现在失效（签名变了/被撤销）」，
    /// 以便给出不同的提示文案，而不是每次都弹同一个框。
    var accessibilityWasGranted: Bool {
        get { registerDefaults(); return defaults.bool(forKey: Key.accessibilityWasGranted) }
        set { defaults.set(newValue, forKey: Key.accessibilityWasGranted) }
    }

    private func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
