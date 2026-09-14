// 移植自 Atoll（https://github.com/Ebullioscopic/Atoll），Copyright (C) 2024-2026 Atoll Contributors，GPL-3.0，见仓库 LICENSE 与 NOTICE。
// 改动：分块循环包一层 autoreleasepool；扫描拆成 scan（按偏移读、返回记录）+ aggregate(records:)，好让 UsageScanCache 只解析新增那段；每行先做字节预筛；`UsageRecord` 加 Codable（扫描缓存要落盘）。上游每块 64 KB 的 NSData 和每行 JSONSerialization 的对象图都是自动释放的，池只在整轮 aggregate 返回时才清，本机 1.1 GB 日志把峰值冲到 2 GB；按块清池后 90 MB，记录数与去重键不变。记账口径：Claude 同一去重键取 output 最大的那行；1 小时档缓存写入按 2 倍 prompt 价；Codex 按相邻两条 total_token_usage 相减（续扫状态 `CodexScanState` 随缓存落盘）。
import Foundation

struct UsageRecord: Codable {
    let timestamp: Date
    let model: String
    /// All prompt tokens, cache hits and cache writes included (what the UI shows).
    let inputTokens: Int
    let outputTokens: Int
    /// Prompt tokens served from the provider cache (subset of `inputTokens`).
    let cacheReadTokens: Int
    /// Prompt tokens written into the provider cache (subset of `inputTokens`).
    let cacheWriteTokens: Int
    /// 其中写进 1 小时档缓存的（`cacheWriteTokens` 的子集）：官方按 2 倍 prompt 价收，表里的 `cache_write` 是 5 分钟档的 1.25 倍。
    let cacheWrite1hTokens: Int
    let dedupKey: String?

    init(timestamp: Date, model: String, inputTokens: Int, outputTokens: Int,
         cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, cacheWrite1hTokens: Int = 0, dedupKey: String?) {
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheWrite1hTokens = cacheWrite1hTokens
        self.dedupKey = dedupKey
    }

    /// Prompt tokens billed at the full prompt rate.
    var uncachedInputTokens: Int { max(0, inputTokens - cacheReadTokens - cacheWriteTokens) }
}

/// Codex 的续扫状态，跨行也跨轮（存进扫描缓存）：`token_count` 不带模型名，要记住最近一条 `turn_context` 的；
/// 记账按相邻两条 `total_token_usage` 相减，要记住上一条的累计值。
struct CodexScanState: Codable, Equatable {
    var model: String?
    var totals: CodexTotals?
}

struct CodexTotals: Codable, Equatable {
    var input = 0
    var cached = 0
    var cacheWrite = 0
    var output = 0

    init(_ raw: [String: Any]) {
        input = raw["input_tokens"] as? Int ?? 0
        cached = raw["cached_input_tokens"] as? Int ?? 0
        cacheWrite = raw["cache_write_input_tokens"] as? Int ?? 0
        output = raw["output_tokens"] as? Int ?? 0
    }

    init() {}

    /// 逐项相减；某一项变小说明换了基线（续接、重算），按新起点记 0。
    func since(_ previous: CodexTotals) -> CodexTotals {
        var delta = CodexTotals()
        delta.input = max(0, input - previous.input)
        delta.cached = max(0, cached - previous.cached)
        delta.cacheWrite = max(0, cacheWrite - previous.cacheWrite)
        delta.output = max(0, output - previous.output)
        return delta
    }
}

struct JSONLUsageParser {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        if let d = iso.date(from: s) { return d }
        return isoPlain.date(from: s)
    }

    static func parseLine(_ line: String) -> UsageRecord? {
        var codex = CodexScanState()
        return parseLine(line, codex: &codex)
    }

    /// `codex` carries the model named by the most recent Codex `turn_context`
    /// record in the same file (`token_count` records do not repeat it, so without
    /// this state every Codex record would be tagged with an unpriceable placeholder)
    /// and the previous `total_token_usage` the next reading is differenced against.
    static func parseLine(_ line: String, codex: inout CodexScanState) -> UsageRecord? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if obj["type"] as? String == "turn_context",
           let payload = obj["payload"] as? [String: Any],
           let model = payload["model"] as? String, !model.isEmpty {
            codex.model = model
            return nil
        }

        if let codexRecord = parseCodexTokenCount(obj, state: &codex) {
            return codexRecord
        }

        let message = obj["message"] as? [String: Any]
        let usage = (message?["usage"] as? [String: Any]) ?? (obj["usage"] as? [String: Any])
        guard let usage else { return nil }
        // Claude Code reports uncached input, cache writes and cache reads as three
        // separate, non-overlapping counters.
        let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheWrite1h = min(cacheWrite, (usage["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0)
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let input = (usage["input_tokens"] as? Int ?? 0) + cacheWrite + cacheRead
        let output = usage["output_tokens"] as? Int ?? 0
        guard input + output > 0 else { return nil }
        let model = (message?["model"] as? String) ?? (obj["model"] as? String) ?? "unknown"
        let tsString = (obj["timestamp"] as? String) ?? (message?["timestamp"] as? String) ?? ""
        guard let ts = parseDate(tsString) else { return nil }
        let messageId = message?["id"] as? String
        let requestId = (obj["requestId"] as? String) ?? (obj["request_id"] as? String)
        let dedupKey = (messageId != nil || requestId != nil) ? "\(messageId ?? "")-\(requestId ?? "")" : nil
        return UsageRecord(timestamp: ts, model: model, inputTokens: input, outputTokens: output,
                           cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite, cacheWrite1hTokens: cacheWrite1h, dedupKey: dedupKey)
    }

    private static func parseCodexTokenCount(_ obj: [String: Any], state: inout CodexScanState) -> UsageRecord? {
        guard obj["type"] as? String == "event_msg",
              let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let timestamp = obj["timestamp"] as? String,
              let date = parseDate(timestamp) else { return nil }

        let usage: CodexTotals
        if let raw = info["total_token_usage"] as? [String: Any] {
            // Codex 会把上一轮的 last_token_usage 原样再报一次（累计值没动），逐条相加就重复记了（本机约 6%）；
            // 相邻两条累计值相减才准。窗口外的旧记录也要走到这一步推进累计值，窗口内第一条的差值才对。
            let total = CodexTotals(raw)
            usage = total.since(state.totals ?? CodexTotals())
            state.totals = total
        } else if let raw = info["last_token_usage"] as? [String: Any] {
            // 没有累计值的老格式只能逐条加
            usage = CodexTotals(raw)
        } else {
            return nil
        }

        // Codex (OpenAI usage semantics): `input_tokens` already includes the cached
        // portion reported in `cached_input_tokens`; cache writes are separate.
        let input = usage.input
        let output = usage.output
        let cacheRead = min(input, usage.cached)
        let cacheWrite = usage.cacheWrite
        guard input >= 0, output >= 0, (input > 0 || output > 0) else { return nil }

        return UsageRecord(
            timestamp: date,
            model: state.model ?? "codex",
            inputTokens: input + cacheWrite,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            dedupKey: nil
        )
    }

    /// Session logs are append-only, so a file whose last write predates the
    /// window cannot contain a record inside it. Returns `true` when the date is
    /// unreadable, so an unexpected filesystem keeps the file rather than
    /// silently dropping its records.
    static func mayContainRecords(after cutoff: Date, _ file: URL) -> Bool {
        guard let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        else { return true }
        return modified >= cutoff
    }

    private static let usageMarker = Data("usage".utf8)
    private static let turnContextMarker = Data("turn_context".utf8)

    /// 一行里这两个词都没有，就既产生不了记录（Claude 看 `usage`，Codex 的 `last_token_usage` 也带这个词）
    /// 也改变不了 Codex 的模型状态（`turn_context`），可以整行跳过，省掉一次 String 构造和一次 JSONSerialization。
    /// 本机周内日志约八万行，只有一万多行过得了这一关。
    static func mayBeInteresting(_ line: Data) -> Bool {
        line.range(of: usageMarker) != nil || line.range(of: turnContextMarker) != nil
    }

    /// 一次扫描的结果。`records` 是以换行结尾的完整行解析出来的，可以进缓存；
    /// `tail` 是文件末尾那半行（还没写完的记录）解析出来的，只算这一轮，不进缓存也不计入 `scannedTo`。
    struct ScanResult {
        var records: [UsageRecord] = []
        var tail: [UsageRecord] = []
        /// 最后一个完整行的结尾偏移，下次从这里接着读。
        var scannedTo: UInt64 = 0
        /// 跨行的 Codex 状态（模型名、上一条累计值），续扫时要带回来。只随完整行推进。
        var codex = CodexScanState()
    }

    /// 从 `offset` 开始逐行读，收出时间戳不早于 `since` 的记录。日志只追加不改写，所以下次可以接着上次的 `scannedTo` 读。
    static func scan(file: URL, since: Date, from offset: UInt64 = 0, codex: CodexScanState = CodexScanState()) -> ScanResult {
        var result = ScanResult(scannedTo: offset, codex: codex)
        guard let handle = try? FileHandle(forReadingFrom: file) else { return result }
        defer { try? handle.close() }
        if offset > 0, (try? handle.seek(toOffset: offset)) == nil { return result }

        var buffer = Data()
        let chunkSize = 64 * 1024 // 64 KB chunks
        let maxRecordSize = 1024 * 1024 // 1 MB max per record
        var discardingOversized = false

        func parse(_ lineData: Data, _ state: inout CodexScanState) -> UsageRecord? {
            guard !lineData.isEmpty, mayBeInteresting(lineData),
                  let line = String(data: lineData, encoding: .utf8),
                  let rec = parseLine(line, codex: &state),
                  rec.timestamp >= since
            else { return nil }
            return rec
        }

        while true {
            // 每块 readData 的 NSData 和每行的 JSON 对象图都是自动释放的，不按块清池就攒到整轮扫描结束。
            let more = autoreleasepool { () -> Bool in
                let chunk = handle.readData(ofLength: chunkSize)
                if chunk.isEmpty { return false }
                buffer.append(chunk)

                // Process complete lines from buffer
                while let newlineRange = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange)
                    buffer.removeSubrange(buffer.startIndex...newlineRange)
                    result.scannedTo += UInt64(lineData.count + 1)

                    if discardingOversized {
                        // We were discarding an oversized record; this newline ends it.
                        discardingOversized = false
                        continue
                    }
                    // Skip oversized terminated records before decoding
                    if lineData.count > maxRecordSize { continue }
                    if let rec = parse(lineData, &result.codex) { result.records.append(rec) }
                }

                // Bound buffer growth: if buffer exceeds maxRecordSize without a newline,
                // discard data up to the next newline when it arrives
                if buffer.count > maxRecordSize {
                    discardingOversized = true
                    let dropped = buffer.count - maxRecordSize
                    result.scannedTo += UInt64(dropped)
                    buffer.removeFirst(dropped)
                }
                return true
            }
            if !more { break }
        }

        // 末尾没有换行的那半行：可能是还没写完的记录，算进这一轮但不算已扫描，下次重读。
        // Codex 状态也不能跟着它推进：下次重读这行时累计值差为 0，这条就丢了
        var scratch = result.codex
        if !buffer.isEmpty, !discardingOversized, buffer.count <= maxRecordSize,
           let rec = parse(buffer, &scratch) {
            result.tail.append(rec)
        }
        return result
    }

    /// 把记录按当前时间窗汇总：周内的算 week，同一天的算 today，5 小时内的算 session；
    /// 带去重键的同一条只算一次（同一条消息会被写进多个文件）。
    static func aggregate(records: [UsageRecord], now: Date) -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        var perModel: [String: UsageTotals] = [:]
        let cal = Calendar.current
        let sessionStart = now.addingTimeInterval(-5 * 3600)
        let weekStart = now.addingTimeInterval(-7 * 86400)

        // 同一个去重键算哪一条：Claude Code 把一条回复按内容块写成好几行，usage 是逐步增长的快照——
        // 输入与缓存数各行相同，只有 output 往上涨，末行才完整。取先见到的那条输出少算三成，所以取 output 最大的。
        var chosen: [String: Int] = [:]
        for (index, rec) in records.enumerated() where rec.timestamp >= weekStart {
            guard let key = rec.dedupKey else { continue }
            if let current = chosen[key], records[current].outputTokens >= rec.outputTokens { continue }
            chosen[key] = index
        }

        for (index, rec) in records.enumerated() {
            guard rec.timestamp >= weekStart else { continue }
            if let key = rec.dedupKey, chosen[key] != index { continue }
            let cost = Self.cost(of: rec)
            func add(_ t: inout UsageTotals) {
                t.inputTokens += rec.inputTokens
                t.outputTokens += rec.outputTokens
                if let cost { t.costUSD += cost } else { t.hasUnpricedModel = true }
            }
            add(&snapshot.week)
            if cal.isDate(rec.timestamp, inSameDayAs: now) { add(&snapshot.today) }
            if rec.timestamp >= sessionStart { add(&snapshot.session) }
            var mt = perModel[rec.model] ?? UsageTotals()
            add(&mt)
            perModel[rec.model] = mt
        }

        snapshot.models = perModel
            .map { ModelUsage(model: $0.key, totals: $0.value, pool: nil) }
            .sorted { $0.totals.costUSD > $1.totals.costUSD }
        snapshot.lastUpdated = now
        return snapshot
    }

    /// 一条记录的费用，没定价返回 nil。`price` 就是 `ModelPricing.cost`，测试换成固定费率。
    /// 1 小时档的缓存写入按 2 倍 prompt 价另算：表里的 `cache_write` 是 5 分钟档（1.25 倍），而 `ModelPricing` 是原样移植的文件不动。
    static func cost(of rec: UsageRecord,
                     price: (_ model: String, _ input: Int, _ output: Int, _ cacheRead: Int, _ cacheWrite: Int) -> Double? = {
                         ModelPricing.cost(model: $0, inputTokens: $1, outputTokens: $2, cacheReadTokens: $3, cacheWriteTokens: $4)
                     }) -> Double? {
        let oneHour = min(rec.cacheWrite1hTokens, rec.cacheWriteTokens)
        guard let base = price(rec.model, rec.uncachedInputTokens, rec.outputTokens, rec.cacheReadTokens, rec.cacheWriteTokens - oneHour)
        else { return nil }
        guard oneHour > 0 else { return base }
        return base + (price(rec.model, 2 * oneHour, 0, 0, 0) ?? 0)
    }

    /// 全量扫一遍。日常刷新走 `UsageScanCache`，只有它和测试用这个。
    static func aggregate(files: [URL], now: Date) -> UsageSnapshot {
        let weekStart = now.addingTimeInterval(-7 * 86400)
        var all: [UsageRecord] = []
        for file in files where mayContainRecords(after: weekStart, file) {
            let scanned = scan(file: file, since: weekStart)
            all += scanned.records
            all += scanned.tail
        }
        return aggregate(records: all, now: now)
    }
}
