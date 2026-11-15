import Foundation
import AppKit

struct StopResult {
    var stopped: Bool = false
    var method: String = "未执行"
    var locked: Bool = false
    var notes: [String] = []

    /// 是否走了「丢进度」的手段（退出 App / 关标签）。用于在 UI 上如实告警。
    var lostProgress: Bool = false
}

/// 到点的附加动作：**勾了开关就一定执行**，与「暂停是否失败」「有没有音频信号」
/// 「浏览器是不是在前台」全都无关。用户要的是「到点收摊」，不是「失败了再补救」。
private struct EndActions {
    let bundleID: String
    let lockScreen: Bool
    let quitClient: Bool
    let closeBrowserTab: Bool
}

/// 停止动作执行器（v1.2：两个「兜底」开关升级为「勾选即执行」的到点动作）。
///
/// ## 两类播放源，两套机制
///
/// | 播放源 | 能否用系统 pause | 判定/停止方式 |
/// |---|---|---|
/// | Edge / Chrome 等 Chromium 浏览器、QuickTime、Music | ✅ 能 | 发 `MRMediaRemoteSendCommand(kMRPause)`，**幂等**，不抢焦点 |
/// | 腾讯视频客户端 | ❌ 不能（不注册 Now Playing） | 只能激活到前台 + 空格 |
///
/// ## 音频信号（只对腾讯视频这类原生播放器可信）
/// `kAudioProcessPropertyIsRunningOutput` 方向不对称：
///   播放 → 暂停：约 **8 秒**才从输出列表消失（客户端先渐弱、再释放设备）
///   暂停 → 播放：约 **1.5 秒**就有输出
/// 因此「无音频」= 可信的「已停」；「有音频」必须等够 `confirmWindow` 才能下结论，
/// 否则会把「刚暂停但设备未释放」误判为失败，再发一次 toggle 把视频重新放起来。
///
/// ⚠️ **浏览器例外**：Edge 的音频挂在 `Microsoft Edge Helper (Aperitif)` 上，
/// 那个标志**永久卡在 1**（暂停后实测 12 秒不回落）。
/// 所以浏览器侧既判断不了在不在播、也验收不了停没停 —— 只能「发出去就算完成」，
/// 好在 pause 幂等，发错无副作用。
///
/// ## 顺序（v1.2）
///   0. 列出当前发声进程（诊断用）
///   1. 系统 pause（无条件发，幂等）
///   2. 腾讯视频在播 → 激活（失败重试一次）→ 空格 → 等静默
///   3. 仍在播 → 媒体键（与键盘焦点无关；焦点在输入框时空格只会打出空格）
///   4. **到点附加动作**（勾了就做，独立于 1~3 的成败）：
///      a. 关闭浏览器标签页：逐个激活运行中的浏览器 → ⌘W
///      b. 退出腾讯视频：terminate，必要时 forceTerminate
///   5. 复核停止状态 → 锁屏
///
/// ## 为什么附加动作放在统一出口 `finishAll`
/// 原来每个分支都是直接 `finish` + `return`，如果只在末尾加动作，
/// 「腾讯视频成功停下」这条最常走的路会整个漏掉。所有出口必须走 `finishAll`。
///
/// ## 已移除的能力（别再走回头路）
/// * **条件兜底**：旧版「退出客户端」只在前面全失败时才执行，「关标签」还要求
///   「检测到音频 + 浏览器已经在前台且绝不抢焦点」。用户勾了却什么都没发生，
///   与「勾选即执行」的直觉完全相反，v1.2 已改为无条件执行。
/// * **AX 直接按暂停控件**：腾讯视频自绘 UI，拿不到控件；且 8 秒静默窗口内无法判定成败。
/// * **读 Now Playing**：`MRMediaRemoteGetNowPlaying*` 在 15.4+ 恒返回 0/null。
final class StopExecutor {

    static let shared = StopExecutor()
    private init() {}

    /// 等待音频释放的窗口。暂停方向实测最长约 9 秒，留出余量。
    private let confirmWindow: TimeInterval = 14.0

    /// 执行停止流程（阻塞式，请放后台队列调用）
    func execute(bundleID: String,
                 lockScreen: Bool,
                 quitClient: Bool,
                 closeBrowserTab: Bool,
                 log: @escaping (String) -> Void,
                 completion: @escaping (StopResult) -> Void) {

        var result = StopResult()
        let actions = EndActions(bundleID: bundleID,
                                 lockScreen: lockScreen,
                                 quitClient: quitClient,
                                 closeBrowserTab: closeBrowserTab)
        let source = NativeAppSource(bundleID: bundleID)

        let clientRunning = source.isRunning
        let clientPlaying = clientRunning && source.state() == .playing

        // 0. 诊断：到底谁在出声
        log("开始停止流程")
        let owners = audioOwners()
        log(owners.isEmpty ? "当前没有进程在输出音频" : "当前发声进程：\(owners.joined(separator: "、"))")
        log("腾讯视频：\(clientRunning ? (clientPlaying ? "正在播放" : "在运行但无音频输出") : "未运行")")
        log("到点附加动作：关闭浏览器标签页 \(closeBrowserTab ? "已勾选（必执行）" : "未勾选") · 退出腾讯视频 \(quitClient ? "已勾选（必执行）" : "未勾选")")

        // 1. 系统 pause（幂等，覆盖浏览器等注册了 Now Playing 的 App）
        let pauseSent = SystemActions.sendSystemPause()
        if pauseSent {
            log("第 1 级：已发送系统暂停（浏览器 / QuickTime / 音乐类 App 由此停下）")
        } else {
            log("第 1 级：系统暂停不可用（MediaRemote 无法加载），跳过")
        }

        if clientPlaying {
            // 2. 腾讯视频不认系统 pause，只能激活 + 空格
            log("第 2 级：腾讯视频不响应系统暂停，改走「激活 + 空格」")
            if pressSpaceAndWait(bundleID: bundleID, source: source, log: log) {
                result.stopped = true
                result.method = "空格键"
                finishAll(result: &result, actions: actions, log: log, completion: completion)
                return
            }
            log("第 2 级未生效")

            // 3. 媒体键（toggle：此时已等满 confirmWindow 仍在出声，说明确实还在播）
            if source.state() == .playing {
                SystemActions.postMediaPlayPause()
                log("第 3 级：确认仍在播放，发送媒体键（与键盘焦点无关）")
                if waitForSilence(source: source, timeout: confirmWindow, log: log) {
                    result.stopped = true
                    result.method = "媒体键"
                    finishAll(result: &result, actions: actions, log: log, completion: completion)
                    return
                }
                log("第 3 级未生效")
            } else {
                log("第 3 级：复核已无音频输出，跳过媒体键以避免误触重播")
                result.stopped = true
                result.method = "复核判定已停止"
                finishAll(result: &result, actions: actions, log: log, completion: completion)
                return
            }

            // 前面几级都没确认停下：如实记账，附加动作会在统一出口里继续收摊
            result.stopped = (source.state() != .playing)
            result.method = result.stopped ? "最终复核判定已停止" : "未确认停止"
            if !result.stopped {
                result.notes.append("暂停未能确认生效，请查看附加动作的执行结果")
            }
        } else {
            // 客户端没在播：只靠系统 pause 这一条
            if pauseSent {
                result.stopped = true
                if owners.isEmpty {
                    result.method = "系统暂停（执行时无音频输出）"
                    result.notes.append("执行时没有进程在输出音频")
                } else {
                    result.method = "系统暂停（浏览器 / 其它播放器）"
                    result.notes.append("该播放源无法用音频信号复核，已按「命令已送达」处理")
                }
            } else if clientRunning {
                result.stopped = true
                result.method = "已处于暂停状态"
                result.notes.append("系统暂停不可用，但客户端本来就没在播")
            } else {
                result.stopped = false
                result.method = "无可用播放源"
                result.notes.append("未找到可执行的停止手段")
            }
        }

        finishAll(result: &result, actions: actions, log: log, completion: completion)
    }

    // MARK: - 私有

    /// 当前正在输出音频的进程（排除自己，避免自检时把自己算成播放源）
    private func audioOwners() -> [String] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        return AudioActivity.shared.audiblyActivePIDs()
            .filter { $0 != myPID }
            .sorted()
            .map { pid -> String in
                // 浏览器等 App 的音频挂在 Helper 子进程上，这类 pid 常常取不到 localizedName。
                // 曾经在这里 `guard let name else { return nil }` 把它丢掉，导致日志写着
                // 「没有进程在输出音频」，下一行却又说「检测到 Edge 在输出音频」——自相矛盾。
                if let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
                    return "\(name)(\(pid))"
                }
                return "pid \(pid)"
            }
    }

    /// 激活到前台 → 发空格 → 等音频释放。
    /// 激活失败是已知的主要失败模式（客户端常驻全屏 Space 时有切 Space 动画），
    /// 所以这里会**重试一次激活**再按键。
    private func pressSpaceAndWait(bundleID: String,
                                   source: PlaybackSource,
                                   log: (String) -> Void) -> Bool {

        var reached = SystemActions.activateAndWait(bundleID: bundleID)
        if !reached {
            log("未能确认客户端已到前台，1 秒后重试激活")
            usleep(1_000_000)
            reached = SystemActions.activateAndWait(bundleID: bundleID)
        }

        if reached {
            log("已激活并确认在前台")
        } else {
            log("警告：仍未确认在前台，空格可能打空（焦点在输入框里时也会变成打空格）")
        }

        SystemActions.postSpace()
        log("已发送空格，等待音频释放（最长 \(Int(confirmWindow)) 秒；实测通常 5~9 秒）")

        return waitForSilence(source: source, timeout: confirmWindow, log: log)
    }

    /// 所有分支的统一出口：先做「勾了就执行」的附加动作，再复核停止状态，最后锁屏。
    private func finishAll(result: inout StopResult,
                           actions: EndActions,
                           log: @escaping (String) -> Void,
                           completion: @escaping (StopResult) -> Void) {

        // a. 关标签先做：它需要把浏览器切到前台；腾讯视频退出放后面，
        //    避免退出时弹出的确认框把焦点抢走，导致 ⌘W 打偏。
        if actions.closeBrowserTab {
            runCloseBrowserTabs(result: &result, log: log)
        } else {
            let running = SystemActions.browsers()
            if !running.isEmpty {
                let names = running.compactMap { $0.localizedName }.joined(separator: "、")
                log("未勾选「关闭浏览器标签页」：\(names) 正在运行，本次不会关闭标签")
            }
        }

        // b. 退出腾讯视频
        if actions.quitClient {
            runQuitClient(result: &result, log: log)
        }

        // c. 附加动作执行完再复核一次：进程退出 / 标签关闭本身就是「收摊」结果，
        //    不能让前面「暂停未确认」把锁屏也一起跳过。
        if actions.closeBrowserTab || actions.quitClient {
            if NativeAppSource(bundleID: actions.bundleID).state() == .playing {
                result.stopped = false
                result.notes.append("附加动作已执行，但腾讯视频仍在播放，请手动检查")
                log("复核：腾讯视频仍在播放")
            } else {
                result.stopped = true
                log("复核：腾讯视频已不在播放，附加动作执行完毕")
            }
        }

        finish(result: &result, lockScreen: actions.lockScreen, log: log, completion: completion)
    }

    /// 附加动作 a：关闭浏览器当前标签页（⌘W）。
    ///
    /// v1.2 起**勾选即执行**：
    ///   * 不再要求「检测到浏览器在输出音频」——那个信号永久卡 1，本来就不可信；
    ///   * 不再要求「浏览器已经在前台且绝不抢焦点」——那样勾了大概率什么都不发生。
    ///     ⌘W 只作用于前台窗口，所以这里主动激活并**等确认**，确保按键不打偏。
    ///
    /// 代价（用户勾选即视为已同意）：浏览器会被切到前台，且关掉的是前台窗口的当前标签，
    /// 可能丢页面状态 / 表单内容；若视频在后台标签，关掉的可能是别的标签。
    /// 演练模式 `VT_CLOSETAB=drill` 走完整识别与激活链路但不真发 ⌘W。
    private func runCloseBrowserTabs(result: inout StopResult, log: (String) -> Void) {
        let drill = ProcessInfo.processInfo.environment["VT_CLOSETAB"] == "drill"

        // 有音频信号的浏览器排在最前（优先关「可能在播」的那个），但不作为执行门槛
        let myPID = ProcessInfo.processInfo.processIdentifier
        let owners = AudioActivity.shared.audiblyActivePIDs().filter { $0 != myPID }
        let audioPIDs = Set(SystemActions.browsersWithAudio(owners: owners).map { $0.processIdentifier })
        var targets = SystemActions.browsers()
        if !audioPIDs.isEmpty {
            targets.sort { audioPIDs.contains($0.processIdentifier) && !audioPIDs.contains($1.processIdentifier) }
        }

        guard !targets.isEmpty else {
            log("附加动作 a：没有运行中的已知浏览器，跳过关标签")
            result.notes.append("未找到运行中的浏览器，关标签未执行")
            return
        }

        let names = targets.compactMap { $0.localizedName }.joined(separator: "、")
        log("附加动作 a：将对 \(names) 逐个激活并关闭其前台标签（勾选即执行，不看是否在播 / 是否在出声）")
        log("注意：会切到前台；⌘W 关的是前台窗口的当前标签，可能丢页面状态")

        var closed: [String] = []
        for app in targets {
            guard let bid = app.bundleIdentifier else { continue }
            let name = app.localizedName ?? bid

            var reached = SystemActions.activateAndWait(bundleID: bid)
            if !reached {
                usleep(600_000)
                reached = SystemActions.activateAndWait(bundleID: bid)
            }
            guard reached else {
                log("\(name) 未能切到前台，跳过（避免 ⌘W 打到别的窗口）")
                continue
            }

            if drill {
                log("演练模式：\(name) 已在前台，跳过实际 ⌘W")
            } else {
                SystemActions.postCloseTab()
                usleep(700_000)
                log("已向 \(name) 发送 ⌘W（关闭的是前台窗口的当前标签）")
            }
            closed.append(name)
        }

        guard !closed.isEmpty else {
            result.notes.append("没有浏览器能切到前台，未执行关标签")
            return
        }

        appendMethod("关闭浏览器标签页 ×\(closed.count)", to: &result)
        result.lostProgress = true
        result.notes.append("浏览器通道无法复核，已按「命令已送达」处理")
        result.notes.append("⌘W 只关前台窗口的当前标签；视频在后台标签时需先把它切到最前")
    }

    /// 附加动作 b：退出腾讯视频客户端。
    ///
    /// v1.2 起**勾选即执行**：不管它在不在播、也不管前面暂停成功没有。
    /// 先优雅 terminate，2 秒内没退掉再强制退出（客户端偶尔会拦一下退出）。
    /// 演练模式 `VT_QUITCLIENT=drill` 只报告目标、不真的退出。
    private func runQuitClient(result: inout StopResult, log: (String) -> Void) {
        let drill = ProcessInfo.processInfo.environment["VT_QUITCLIENT"] == "drill"
        let apps = SystemActions.runningClients()

        guard !apps.isEmpty else {
            log("附加动作 b：腾讯视频未运行，无需关闭")
            return
        }

        let names = apps.compactMap { $0.localizedName }.joined(separator: "、")
        log("附加动作 b：退出腾讯视频（\(names)）—— 勾选即执行，会丢失播放进度")

        if drill {
            log("演练模式：跳过实际退出")
            appendMethod("退出腾讯视频（演练）", to: &result)
            return
        }

        for app in apps { app.terminate() }

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline && !SystemActions.runningClients().isEmpty {
            usleep(200_000)
        }

        var left = SystemActions.runningClients()
        if !left.isEmpty {
            log("优雅退出未生效，改用强制退出")
            for app in left { app.forceTerminate() }
            usleep(800_000)
            left = SystemActions.runningClients()
        }

        if left.isEmpty {
            appendMethod("退出腾讯视频", to: &result)
            result.lostProgress = true
            result.notes.append("腾讯视频已退出，播放进度已丢失")
            log("腾讯视频已关闭")
        } else {
            result.notes.append("腾讯视频仍在运行（可能弹了确认框），请手动关闭")
            log("警告：腾讯视频仍在运行，未能确认关闭")
        }
    }

    /// 把附加动作追加到「方式」里，保留前面暂停手段的记录
    private func appendMethod(_ name: String, to result: inout StopResult) {
        if result.method.isEmpty || result.method == "未执行" {
            result.method = name
        } else {
            result.method += " + \(name)"
        }
    }

    private func finish(result: inout StopResult,
                        lockScreen: Bool,
                        log: @escaping (String) -> Void,
                        completion: @escaping (StopResult) -> Void) {

        if lockScreen {
            // 硬约束：锁屏不中断后台播放，必须严格在停止之后
            if result.stopped {
                log("停止已确认，执行锁屏（Control+Command+Q）")
                var ok = SystemActions.lockScreen()
                if !ok {
                    log("CGEvent 锁屏未生效，改用 System Events 重试")
                    ok = SystemActions.lockScreenViaAppleScript()
                }
                result.locked = ok
                log(ok ? "锁屏成功" : "锁屏未确认，请检查辅助功能/自动化权限")
            } else {
                log("未能确认播放已停止，为避免「锁屏后继续放声音」，本次跳过锁屏")
                result.notes.append("因停止未确认，锁屏被跳过")
            }
        } else {
            log("未启用锁屏，跳过")
        }

        if result.lostProgress {
            log("提醒：本次用了「退出客户端 / 关闭标签页」这类不可逆手段，播放进度或页面状态已丢失")
        }

        result.notes.append("方式：\(result.method)")
        log("流程结束 · \(result.method)")
        completion(result)
    }

    /// 轮询等待音频输出消失。客户端退出也算停止。
    private func waitForSilence(source: PlaybackSource, timeout: TimeInterval, log: (String) -> Void) -> Bool {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var lastReport = 0
        while Date() < deadline {
            if !source.isRunning { return true }
            if source.state() != .playing { return true }
            let elapsed = Int(Date().timeIntervalSince(start))
            // 每 5 秒给一条进度，避免界面长时间无反馈
            if elapsed > 0 && elapsed % 5 == 0 && elapsed != lastReport {
                lastReport = elapsed
                log("仍在等待音频释放… 已 \(elapsed) 秒（暂停后设备释放通常需要 5~9 秒）")
            }
            usleep(250_000)
        }
        return source.state() != .playing
    }
}
