import AppKit
import Foundation

enum PlaybackEndReason: String {
    case audioSilent = "音频静默（本集结束/已暂停）"
    case appTerminated = "客户端已退出"
    case maxWaitReached = "到达最长等待上限（降级触发）"

    var display: String { rawValue }
}

/// 「播完当前再停」的事件监听器。
///
/// 原理：不猜片尾，只观测「播放停止」这一个状态变化。
/// v1 用两条信号，任一触发即可：
///   A. CoreAudio 进程级音频输出由「有」→「无」，且持续静默一段时间（防缓冲/换集抖动）
///   B. NSWorkspace 客户端进程退出
/// 两条都不来，则由 TimerEngine 的最长等待上限兜底。
///
/// ## 精度（对用户只能说这么多，别承诺更准）
/// 触发时刻 = 真正播完 + 音频设备释放（实测约 8 秒）+ `silenceThreshold`。
/// 也就是**本集结束后大约 10~11 秒**才会真正暂停并锁屏。
/// 客户端不暴露播放进度（非 Electron、读不到 Now Playing、AX 无控件），
/// 所以做不到「片尾字幕一出来就停」。
///
/// ## 已知失效场景：客户端开了「自动连播」
/// 下一集在 1~3 秒内就会接上，音频信号**根本不会掉到 0**，
/// 于是 A 条件永远不触发，只能等 `maxWait` 兜底（表现为「播完当前」变成了「一直播」）。
/// 需要用户在客户端里关掉自动连播，或改用「到点立即停止」。
final class PlaybackEndMonitor {

    private var workspaceObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var maxWaitTimer: Timer?
    private var onEnd: ((PlaybackEndReason) -> Void)?
    private var bundleID: String = ""
    private var fired = false

    private var seenPlaying = false
    private var silentSince: Date?
    private var playingAccumulated: TimeInterval = 0
    private var lastPoll: Date = Date()

    /// 静默多久才认定「播完了」（缓冲、切集会有短暂静默）。
    /// 注意：音频信号本身有滞后——客户端暂停后要约 8 秒才释放音频设备，
    /// 因此实际触发时间约为「真正停止 + 8 秒 + 本阈值」。这对「睡前停」可接受。
    private let silenceThreshold: TimeInterval = 2.5
    /// 至少要真的播放过这么久，才允许「静默」被当成结束（避免一开就误判）
    private let minimumWatched: TimeInterval = 15

    var isListening: Bool { pollTimer != nil }

    func start(bundleID: String,
               maxWait: TimeInterval,
               onEnd: @escaping (PlaybackEndReason) -> Void) {
        stop()
        self.bundleID = bundleID
        self.onEnd = onEnd
        fired = false
        seenPlaying = false
        silentSince = nil
        playingAccumulated = 0
        lastPoll = Date()

        // A. 音频静默轮询
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t

        // B. 客户端退出
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == self.bundleID else { return }
                self.fire(.appTerminated)
            }

        // C. 最长等待兜底
        let m = Timer(timeInterval: max(maxWait, 60), repeats: false) { [weak self] _ in
            self?.fire(.maxWaitReached)
        }
        RunLoop.main.add(m, forMode: .common)
        maxWaitTimer = m
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        maxWaitTimer?.invalidate(); maxWaitTimer = nil
        if let o = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        workspaceObserver = nil
        onEnd = nil
        seenPlaying = false
        silentSince = nil
    }

    // MARK: - 私有

    private func poll() {
        guard !fired else { return }
        let now = Date()
        let delta = now.timeIntervalSince(lastPoll)
        lastPoll = now

        guard let pid = SystemActions.runningApp(bundleID: bundleID)?.processIdentifier else {
            // 进程没了也算结束
            fire(.appTerminated)
            return
        }

        let playing = AudioActivity.shared.isOutputActive(pid: pid)

        if playing {
            seenPlaying = true
            silentSince = nil
            playingAccumulated += delta
            return
        }

        guard seenPlaying, playingAccumulated >= minimumWatched else { return }
        if silentSince == nil {
            silentSince = now
            return
        }
        if let s = silentSince, now.timeIntervalSince(s) >= silenceThreshold {
            fire(.audioSilent)
        }
    }

    private func fire(_ reason: PlaybackEndReason) {
        guard !fired else { return }
        fired = true
        let cb = onEnd
        stop()
        DispatchQueue.main.async { cb?(reason) }
    }
}
