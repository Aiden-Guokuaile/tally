import Foundation

/// Claude 配额的读取端：statusline 每次渲染都把 Claude Code 喂给它的 `rate_limits`
/// 写到 `$TMPDIR/claude-agent-state/rate-limits.json`，这里只读那份缓存，不碰任何凭据。
struct ClaudeLimits: Equatable {
    var session: UsageLimit?
    var week: UsageLimit?
    /// 按模型分的周窗口（如 Fable）。只有官方接口给，statusline 缓存里没有，所以缓存读出来永远是空的。
    var scoped: [ScopedLimit] = []
    /// 缓存文件超过 10 分钟没更新。没有 Claude 会话在跑时就是这样，配额也没人消耗。
    var isStale: Bool
}

struct ClaudeLimitsCache {

    static let staleAfter: TimeInterval = 600

    let directory: URL

    /// `NSTemporaryDirectory()` 和 shell 的 `$TMPDIR` 都来自 `confstr(_CS_DARWIN_USER_TEMP_DIR)`，是同一个目录。
    init(directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("claude-agent-state")) {
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent("rate-limits.json") }

    /// 文件不存在、读不了、顶层不是对象、两个窗口都缺：nil。其余情况按窗口各自解析。
    func read(now: Date = .now) -> ClaudeLimits? {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let session = Self.limit(from: object["five_hour"])
        let week = Self.limit(from: object["seven_day"])
        guard session != nil || week != nil else { return nil }
        return ClaudeLimits(session: session, week: week, isStale: Self.isStale(fileURL, now: now))
    }

    /// `used_percentage` 按 Double 解码，`88` 得 0.88；超限时可能大于 100，不截断，`fraction` 自己封顶。
    /// `resets_at` 是 Unix 秒；缺失或不是数值时 resetsAt 为 nil。
    private static func limit(from raw: Any?) -> UsageLimit? {
        guard let window = raw as? [String: Any],
              let used = Self.number(window["used_percentage"])
        else { return nil }
        let resetsAt = Self.number(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        return UsageLimit(used: used / 100, limit: 1, resetsAt: resetsAt)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    /// mtime 距 now 严格大于 600 秒才算陈旧；mtime 在未来视为不陈旧。
    private static func isStale(_ url: URL, now: Date) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date
        else { return true }
        return now.timeIntervalSince(modified) > staleAfter
    }
}
