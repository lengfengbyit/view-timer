import Foundation
import AppKit

// 播放源抽象：v2 增加 Edge 网页渠道时，只需新增 BrowserExtensionSource，
// 本执行器与状态机、UI 完全复用。
protocol PlaybackSource: AnyObject {
    var identifier: String { get }
    var isRunning: Bool { get }
    var pid: pid_t? { get }
    /// 当前播放状态（v1 用 CoreAudio 进程音频输出判定）
    func state() -> PlayerState
}

final class NativeAppSource: PlaybackSource {

    let identifier: String

    init(bundleID: String) {
        self.identifier = bundleID
    }

    var isRunning: Bool { SystemActions.isRunning(bundleID: identifier) }

    var pid: pid_t? { SystemActions.runningApp(bundleID: identifier)?.processIdentifier }

    func state() -> PlayerState {
        guard let pid = pid else { return .notRunning }
        return AudioActivity.shared.isOutputActive(pid: pid) ? .playing : .paused
    }
}
