import Foundation
import CoreAudio
import AppKit

/// 播放状态：v1 判定「腾讯视频到底是不是在播」的唯一可用来源。
///
/// 为什么不用 MediaRemote 读：macOS 15.4+ 起 `MRMediaRemoteGetNowPlayingInfo` /
/// `...GetNowPlayingApplicationPID` 对第三方进程一律返回 null / 0，
/// **连自己刚注册 NowPlayingInfo 的进程也读不到**（2026-11 实测确认）。
///
/// 注意：**「读」被封不等于「写」被封**。
/// `MRMediaRemoteSendCommand(kMRPause)` 仍然可用，前提是发送进程活够约 1.5 秒
/// （异步 XPC，发完立刻退出会静默丢包）——但它只投递给「已注册 Now Playing」的 App，
/// 而腾讯视频不注册，所以对 v1 主渠道无效。细节见 `StopExecutor` 的类注释。
///
/// 改用 CoreAudio 的「进程级音频输出」：`kAudioProcessPropertyIsRunningOutput` 为 1
/// 表示该进程正在向音频设备写数据。公开 API、无需任何权限、无需辅助功能。
///
/// **实测特性（重要，调用方必须按此设计超时）**：
/// * 播放 → 暂停：进程的音频对象要 **约 8 秒**才从输出列表消失（客户端先渐弱再释放设备）。
///   所以刚暂停的头几秒里仍然读得到「有输出」，此时不能判定为「暂停失败」。
/// * 暂停 → 播放：**约 1.5 秒**就有输出。
/// * 由此：「无输出」= 可信的「已停止」；「有输出」= 可能仍在播，也可能刚暂停，
///   需要等够约 14 秒才能下结论。
///
/// 另外：客户端内静音时同样会读到「无输出」，但那种情况下我们判定「已暂停」而跳过按键，
/// 结果也只是「本来就没声音」，没有副作用。
enum PlayerState {
    case notRunning     // 客户端没开
    case playing        // 客户端在跑，且正在输出音频
    case paused         // 客户端在跑，但没有音频输出
    case unknown        // 读不到（极端情况）

    var isPlaying: Bool { self == .playing }
}

final class AudioActivity {

    static let shared = AudioActivity()
    private init() {}

    private var cachePIDs: Set<pid_t> = []
    private var cacheTime: Date = .distantPast
    private let cacheTTL: TimeInterval = 0.15

    // MARK: - CoreAudio 四字符码

    private static func sel(_ s: String) -> AudioObjectPropertySelector {
        var r: UInt32 = 0
        for c in s.utf8 { r = (r << 8) + UInt32(c) }
        return r
    }

    private static let selProcessObjectList = sel("prs#")
    private static let selPID = sel("ppid")
    private static let selRunningOutput = sel("piro")

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// 当前正在输出音频的所有进程 pid
    func audiblyActivePIDs() -> Set<pid_t> {
        if Date().timeIntervalSince(cacheTime) < cacheTTL { return cachePIDs }

        var result: Set<pid_t> = []
        var addr = address(Self.selProcessObjectList)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)

        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else {
            cachePIDs = []; cacheTime = Date()
            return []
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else {
            cachePIDs = []; cacheTime = Date()
            return []
        }

        for obj in ids {
            var outAddr = address(Self.selRunningOutput)
            var isRunning: UInt32 = 0
            var outSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(obj, &outAddr, 0, nil, &outSize, &isRunning) == noErr,
                  isRunning == 1 else { continue }

            var pidAddr = address(Self.selPID)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(obj, &pidAddr, 0, nil, &pidSize, &pid) == noErr else { continue }
            result.insert(pid)
        }

        cachePIDs = result
        cacheTime = Date()
        return result
    }

    func isOutputActive(pid: pid_t) -> Bool { audiblyActivePIDs().contains(pid) }
}
