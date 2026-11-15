import Foundation

/// 面板里的执行日志（环形缓冲）
final class LogStore {

    enum Level {
        case info, ok, warn, err
    }

    struct Line {
        let time: Date
        let text: String
        let level: Level
    }

    static let shared = LogStore()
    private init() {}

    private(set) var lines: [Line] = []
    var onChange: (() -> Void)?
    private let capacity = 200

    func add(_ text: String, level: Level = .info) {
        lines.append(Line(time: Date(), text: text, level: level))
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        NSLog("[view-timer] \(text)")
        onChange?()
    }

    func clear() {
        lines.removeAll()
        onChange?()
    }
}
