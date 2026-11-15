import Foundation

enum TimerState {
    case idle
    case running
    case warning
    case executing
    case done

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "计时中"
        case .warning: return "即将执行"
        case .executing: return "执行中"
        case .done: return "已完成"
        }
    }
}

struct TimerConfig {
    var minutes: Int = 45
    var strategy: StopStrategy = .now
    var lockScreen: Bool = true
    var fullScreenAlert: Bool = true
    var soundAlert: Bool = false
    var quitClient: Bool = false
    var closeBrowserTab: Bool = false
    var warnBeforeSeconds: TimeInterval = 10
    var episodeRemainingMinutes: Int = 35
    var maxWaitMinutes: Int = 120

    /// 本次计时真正要等的秒数
    var effectiveSeconds: TimeInterval {
        switch strategy {
        case .now:
            return TimeInterval(minutes * 60)
        case .episode:
            let capped = min(episodeRemainingMinutes, maxWaitMinutes)
            return TimeInterval(max(capped, 1) * 60)
        }
    }
}

// 纯本地状态机，与播放源解耦：v2 增加网页渠道时只需替换触发条件。
final class TimerEngine {

    private(set) var state: TimerState = .idle
    private(set) var deadline: Date?
    private(set) var totalDuration: TimeInterval = 0
    private var config = TimerConfig()
    private var timer: Timer?
    private var didWarn = false

    var onTick: ((TimeInterval) -> Void)?
    var onWarning: (() -> Void)?
    var onFire: (() -> Void)?
    var onStateChange: ((TimerState) -> Void)?

    func start(config: TimerConfig) {
        stopTimer()
        self.config = config
        self.totalDuration = config.effectiveSeconds
        self.deadline = Date().addingTimeInterval(totalDuration)
        self.didWarn = false
        setState(.running)
        onTick?(totalDuration)

        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 由 PlaybackEndMonitor 在检测到「播放停止」时调用
    func fireNow() {
        guard state == .running || state == .warning else { return }
        deadline = Date()
        tick()
    }

    func snooze(minutes: Int = 5) {
        guard state == .running || state == .warning else { return }
        deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        didWarn = false
        setState(.running)
        onTick?(TimeInterval(minutes * 60))
    }

    func cancel() {
        stopTimer()
        deadline = nil
        didWarn = false
        setState(.idle)
    }

    func markDone() {
        stopTimer()
        deadline = nil
        setState(.done)
    }

    func backToIdle() {
        stopTimer()
        deadline = nil
        didWarn = false
        setState(.idle)
    }

    var remaining: TimeInterval {
        guard let deadline else { return 0 }
        return max(0, deadline.timeIntervalSinceNow)
    }

    // MARK: - 私有

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func setState(_ s: TimerState) {
        state = s
        onStateChange?(s)
    }

    private func tick() {
        guard let deadline, state == .running || state == .warning else { return }
        let remain = deadline.timeIntervalSinceNow
        onTick?(max(0, remain))

        if config.fullScreenAlert, !didWarn, remain <= config.warnBeforeSeconds, remain > 0 {
            didWarn = true
            setState(.warning)
            onWarning?()
        }

        if remain <= 0 {
            stopTimer()
            setState(.executing)
            onFire?()
        }
    }
}
