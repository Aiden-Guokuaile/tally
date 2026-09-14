import Foundation

/// 用量日志的增量扫描。会话日志只追加不改写：文件没变就沿用上次解析出的记录，长大了只解析新增那一段。
///
/// 为什么要它：本机 Claude 周内日志 480 MB、Codex 更多，全量重扫一次约二十秒，而刷新是每 5 分钟一次、
/// 展开面板还要再来一次——「Claude 那行一直加载中」就是这么来的。缓存之后每轮只读活跃会话新写的那几十 KB。
///
/// 记录本身很小（周内约两万条），整份缓存几 MB；窗口往前挪时把过期记录扔掉，不会无限长。
/// 缓存还落盘：不落的话每次开 app 都要再全量扫一次（本机 14 秒），落了之后重启也是增量。
final class UsageScanCache: @unchecked Sendable {

    private struct Entry: Codable {
        var scannedTo: UInt64 = 0
        /// Codex 的模型名与上一条累计值，续扫从这里接着减。
        var codex = CodexScanState()
        var records: [UsageRecord] = []
    }

    /// 落盘格式变了就整份作废重扫，不做迁移。2：记录加 1 小时档缓存写入、Codex 改按累计值相减。
    private static let formatVersion = 2

    private struct Stored: Codable {
        var version: Int
        var entries: [String: Entry]
    }

    /// 落盘节流：两份缓存加起来七八 MB，活跃时每 5 分钟就有新数据，每次都写一天要往盘上砸两个 G。
    /// 隔半小时写一次就够：中间丢的那点进度，下次启动只是多读半小时的新增日志（几 MB）。
    static let saveInterval: TimeInterval = 1800

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var scannedBytes: UInt64 = 0
    private var lastSaved: Date?
    private let storeURL: URL?

    /// 上一轮真正读了多少字节。排查和用例用。
    var lastScannedBytes: UInt64 { lock.withLock { scannedBytes } }

    /// `name` 为 nil 就不落盘（测试用）。
    init(name: String? = nil, directory: URL = PreferencesStore.directory.appendingPathComponent("scan-cache")) {
        storeURL = name.map { directory.appendingPathComponent("\($0).json") }
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.version == Self.formatVersion
        else { return }
        entries = stored.entries
    }

    func aggregate(files: [URL], now: Date) -> UsageSnapshot {
        let weekStart = now.addingTimeInterval(-7 * 86400)
        let previous = lock.withLock { entries }
        var fresh: [String: Entry] = [:]
        var all: [UsageRecord] = []
        var read: UInt64 = 0

        for file in files {
            let path = file.path
            // 用 FileManager 直接 stat，不用 URL 的资源值：那玩意会缓存在 URL 对象上，
            // 同一个 URL 再问一次拿到的还是旧的大小，文件长大了也看不见。
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            let modified = attributes?[.modificationDate] as? Date
            // 最后一次写都早于周窗口的文件，里面不可能有窗口内的记录（日志只追加）；读不到日期就当它有
            guard modified == nil || modified! >= weekStart else { continue }
            var entry = previous[path] ?? Entry()
            // 比上次还短：被截断或换了同名文件，之前解析的记录都不作数，从头再来
            if entry.scannedTo > size { entry = Entry() }

            var tail: [UsageRecord] = []
            if size > entry.scannedTo {
                let scanned = JSONLUsageParser.scan(file: file, since: weekStart, from: entry.scannedTo, codex: entry.codex)
                read += scanned.scannedTo >= entry.scannedTo ? scanned.scannedTo - entry.scannedTo : 0
                entry.records += scanned.records
                entry.scannedTo = scanned.scannedTo
                entry.codex = scanned.codex
                tail = scanned.tail
            }
            // 窗口往前挪，掉出周窗口的记录扔掉
            entry.records.removeAll { $0.timestamp < weekStart }
            fresh[path] = entry
            all += entry.records
            all += tail
        }

        // fresh 里没有的文件（被删了、或已经老到进不了周窗口）跟着这一轮一起丢掉
        let shouldSave: Bool = lock.withLock {
            let changed = read > 0 || fresh.keys != entries.keys
            entries = fresh
            scannedBytes = read
            // 第一次填满一定要写（那次是最贵的全扫），之后隔半小时写一次
            guard changed else { return false }
            guard let last = lastSaved else { return true }
            return Date().timeIntervalSince(last) >= Self.saveInterval
        }
        if shouldSave { flush() }
        return JSONLUsageParser.aggregate(records: all, now: now)
    }

    /// 把当前缓存写盘。退出前也叫一次，省得半小时的进度白丢。
    func flush() {
        let snapshot: [String: Entry] = lock.withLock {
            lastSaved = Date()
            return entries
        }
        save(snapshot)
    }

    private func save(_ entries: [String: Entry]) {
        guard let storeURL else { return }
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Stored(version: Self.formatVersion, entries: entries)).write(to: storeURL, options: .atomic)
        } catch {
            Log.error("扫描缓存写入失败: \(error.localizedDescription)")
        }
    }
}
