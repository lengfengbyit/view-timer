import Foundation
import Darwin

/// 进程级活动度采样。
///
/// 为什么需要它：腾讯视频暂停后**不会释放音频设备**（CoreAudio 的
/// `IsRunningOutput` 仍为 1），所以「无音频输出」不能当作「已暂停」；
/// 反过来静音播放时又确实没有音频输出。单靠音频两头都会误判。
///
/// CPU 是更稳的第二信号：解码/渲染中的进程 CPU 明显高于暂停态（实测约
/// 40% vs 个位数百分比），且 `proc_pidinfo` 是公开 API，不需要任何权限。
enum ProcessActivity {

    /// 进程累计占用的 CPU 秒数（user + system）
    static func cpuSeconds(pid: pid_t) -> Double? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard got == size else { return nil }
        return Double(info.pti_total_user + info.pti_total_system) / 1_000_000_000.0
    }

    /// 采样窗口内的平均 CPU 占用（0~100，单核口径）
    static func cpuPercent(pid: pid_t, window: TimeInterval = 0.6) -> Double? {
        guard let a = cpuSeconds(pid: pid) else { return nil }
        Thread.sleep(forTimeInterval: window)
        guard let b = cpuSeconds(pid: pid) else { return nil }
        guard window > 0 else { return nil }
        return max(0, (b - a) / window * 100.0)
    }
}
