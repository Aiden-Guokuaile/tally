import Foundation

/// 配额接口回 429 之后按接口退避（docs/ai.md「429 按接口退避」）。落盘：重开 app 不会立刻又撞上去。
/// 引用类型、自己加锁：客户端是 struct，被 provider 存着复制来复制去，还会在后台任务里并发用。
final class QuotaBackoff: @unchecked Sendable {
    static let base: TimeInterval = 60
    static let cap: TimeInterval = 15 * 60

    /// 真 app 用的那一份，写 Application Support；客户端的默认参数和测试用不落盘的。
    static let shared = QuotaBackoff(file: PreferencesStore.directory.appendingPathComponent("quota-backoff.json"))

    struct Entry: Codable, Equatable {
        var until: Date
        var delay: TimeInterval
    }

    private let lock = NSLock()
    private let file: URL?
    private var entries: [String: Entry]

    init(file: URL? = nil) {
        self.file = file
        // 文件没有或坏了就当从没退避过：最坏是多撞一次 429
        entries = file.flatMap { try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: $0)) } ?? [:]
    }

    /// 下一次退避多久：第一次 60 秒，之后翻倍，封顶 15 分钟；`Retry-After` 更长就听它的（同样封顶）。
    static func nextDelay(previous: TimeInterval?, retryAfter: TimeInterval?) -> TimeInterval {
        let doubled = previous.map { min($0 * 2, cap) } ?? base
        return max(doubled, min(retryAfter ?? 0, cap))
    }

    func allows(_ key: String, now: Date) -> Bool {
        lock.withLock { entries[key].map { now >= $0.until } ?? true }
    }

    func throttled(_ key: String, now: Date, retryAfter: TimeInterval?) {
        let snapshot: [String: Entry] = lock.withLock {
            let delay = Self.nextDelay(previous: entries[key]?.delay, retryAfter: retryAfter)
            entries[key] = Entry(until: now.addingTimeInterval(delay), delay: delay)
            return entries
        }
        save(snapshot)
    }

    func succeeded(_ key: String) {
        let snapshot: [String: Entry]? = lock.withLock {
            guard entries.removeValue(forKey: key) != nil else { return nil }
            return entries
        }
        if let snapshot { save(snapshot) }
    }

    /// `Retry-After` 只认秒数；HTTP 日期格式的按没给处理。
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        response.value(forHTTPHeaderField: "Retry-After").flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func save(_ snapshot: [String: Entry]) {
        guard let file else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: file, options: .atomic)
        } catch {
            // 写不进去只是重开 app 后忘了退避，内存里照样生效
            Log.error("配额退避状态写不进去: \(error.localizedDescription)")
        }
    }
}
