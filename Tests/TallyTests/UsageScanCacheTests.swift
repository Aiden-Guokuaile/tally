import XCTest
@testable import Tally

final class UsageScanCacheTests: XCTestCase {

    private var directory = URL(fileURLWithPath: "/dev/null")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tally-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func line(_ minutesAgo: Int, tokens: Int, id: String, now: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        let ts = f.string(from: now.addingTimeInterval(-Double(minutesAgo) * 60))
        return #"{"timestamp":"\#(ts)","requestId":"\#(id)","message":{"id":"m\#(id)","model":"claude-sonnet-4-5","usage":{"input_tokens":\#(tokens),"output_tokens":\#(tokens)}}}"# + "\n"
    }

    private func write(_ text: String, to name: String, append: Bool = false) throws -> URL {
        let url = directory.appendingPathComponent(name)
        if append, let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: url)
        }
        return url
    }

    func testOnlyReadsTheAppendedTailOnSecondRun() throws {
        let now = Date()
        let url = try write(line(10, tokens: 100, id: "a", now: now) + line(20, tokens: 100, id: "b", now: now), to: "s.jsonl")
        let cache = UsageScanCache()

        let first = cache.aggregate(files: [url], now: now)
        XCTAssertEqual(first.week.inputTokens, 200)
        let firstBytes = cache.lastScannedBytes
        XCTAssertGreaterThan(firstBytes, 0)

        // 一个字节都没变：不该再读
        let again = cache.aggregate(files: [url], now: now)
        XCTAssertEqual(again.week.inputTokens, 200, "沿用缓存，结果不变")
        XCTAssertEqual(cache.lastScannedBytes, 0, "文件没变就一个字节都不读")

        // 追加一条：只读新增那段
        let added = line(1, tokens: 50, id: "c", now: now)
        _ = try write(added, to: "s.jsonl", append: true)
        let third = cache.aggregate(files: [url], now: now)
        XCTAssertEqual(third.week.inputTokens, 250)
        XCTAssertEqual(cache.lastScannedBytes, UInt64(added.utf8.count), "只读追加的那几十字节")
    }

    func testSameResultAsFullScan() throws {
        let now = Date()
        let url = try write(line(5, tokens: 30, id: "x", now: now)
            + line(60, tokens: 40, id: "y", now: now)
            + line(9 * 24 * 60, tokens: 999, id: "old", now: now), to: "s.jsonl")
        let cached = UsageScanCache().aggregate(files: [url], now: now)
        let full = JSONLUsageParser.aggregate(files: [url], now: now)
        XCTAssertEqual(cached.week.inputTokens, full.week.inputTokens)
        XCTAssertEqual(cached.today.inputTokens, full.today.inputTokens)
        XCTAssertEqual(cached.session.inputTokens, full.session.inputTokens)
        XCTAssertEqual(cached.week.inputTokens, 70, "周窗口外的那条不算")
    }

    func testTruncatedFileIsRescannedFromScratch() throws {
        let now = Date()
        let url = try write(line(10, tokens: 100, id: "a", now: now) + line(11, tokens: 100, id: "b", now: now), to: "s.jsonl")
        let cache = UsageScanCache()
        XCTAssertEqual(cache.aggregate(files: [url], now: now).week.inputTokens, 200)
        // 换成一个更短的同名文件：之前解析的都不作数
        _ = try write(line(12, tokens: 7, id: "z", now: now), to: "s.jsonl")
        XCTAssertEqual(cache.aggregate(files: [url], now: now).week.inputTokens, 7)
    }

    func testUnterminatedTailCountsButIsRescanned() throws {
        let now = Date()
        let complete = line(10, tokens: 100, id: "a", now: now)
        let partial = String(line(5, tokens: 60, id: "b", now: now).dropLast())  // 结尾没有换行
        let url = try write(complete + partial, to: "s.jsonl")
        let cache = UsageScanCache()
        XCTAssertEqual(cache.aggregate(files: [url], now: now).week.inputTokens, 160, "半行也算这一轮")
        XCTAssertEqual(cache.aggregate(files: [url], now: now).week.inputTokens, 160, "重扫半行，不会算两次")
        // 补上换行后它变成完整行，仍然只算一次
        _ = try write("\n", to: "s.jsonl", append: true)
        XCTAssertEqual(cache.aggregate(files: [url], now: now).week.inputTokens, 160)
    }

    func testSurvivesRelaunchThroughDisk() throws {
        let now = Date()
        let url = try write(line(10, tokens: 100, id: "a", now: now) + line(20, tokens: 100, id: "b", now: now), to: "s.jsonl")
        let store = directory.appendingPathComponent("cache")

        let first = UsageScanCache(name: "t", directory: store)
        XCTAssertEqual(first.aggregate(files: [url], now: now).week.inputTokens, 200)
        XCTAssertGreaterThan(first.lastScannedBytes, 0)

        // 换一个实例，等于重开 app：读盘上的缓存，一个字节都不用再读
        let second = UsageScanCache(name: "t", directory: store)
        XCTAssertEqual(second.aggregate(files: [url], now: now).week.inputTokens, 200)
        XCTAssertEqual(second.lastScannedBytes, 0, "重开 app 也是增量")

        // 盘上的缓存坏了就整份作废重扫，不崩
        try Data("{ broken".utf8).write(to: store.appendingPathComponent("t.json"))
        let third = UsageScanCache(name: "t", directory: store)
        XCTAssertEqual(third.aggregate(files: [url], now: now).week.inputTokens, 200)
        XCTAssertGreaterThan(third.lastScannedBytes, 0, "坏缓存丢掉，重新全扫")
    }

    func testPrefilterKeepsCodexModelState() {
        XCTAssertTrue(JSONLUsageParser.mayBeInteresting(Data(#"{"type":"turn_context","payload":{"model":"gpt-6"}}"#.utf8)), "Codex 的模型状态行要留着")
        XCTAssertTrue(JSONLUsageParser.mayBeInteresting(Data(#"{"message":{"usage":{"input_tokens":1}}}"#.utf8)))
        XCTAssertFalse(JSONLUsageParser.mayBeInteresting(Data(#"{"type":"user","message":{"content":"hello"}}"#.utf8)), "既没 usage 也没 turn_context，跳过")
    }

    // MARK: 记账口径

    private func stamp(_ minutesAgo: Int, now: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: now.addingTimeInterval(-Double(minutesAgo) * 60))
    }

    /// Claude Code 同一条回复按内容块写成的一行：输入与缓存数各行相同，output 是写这行时的快照。
    private func claudeBlock(_ minutesAgo: Int, output: Int, now: Date) -> String {
        #"{"timestamp":"\#(stamp(minutesAgo, now: now))","requestId":"req","message":{"id":"msg","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":500,"cache_creation_input_tokens":90,"output_tokens":\#(output)}}}"# + "\n"
    }

    private func codexCount(_ minutesAgo: Int, total: (Int, Int), last: (Int, Int), now: Date) -> String {
        #"{"type":"event_msg","timestamp":"\#(stamp(minutesAgo, now: now))","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total.0),"cached_input_tokens":0,"output_tokens":\#(total.1)},"last_token_usage":{"input_tokens":\#(last.0),"cached_input_tokens":0,"output_tokens":\#(last.1)}}}}"# + "\n"
    }

    func testClaudeMessageSplitAcrossLinesCountsItsLargestOutput() throws {
        let now = Date()
        // 先写出来的行 output 小，末行才完整：只认首行的话这条记成 2 而不是 180
        let url = try write(claudeBlock(3, output: 2, now: now) + claudeBlock(3, output: 40, now: now) + claudeBlock(3, output: 180, now: now), to: "c.jsonl")
        let week = UsageScanCache().aggregate(files: [url], now: now).week
        XCTAssertEqual(week.outputTokens, 180)
        XCTAssertEqual(week.inputTokens, 600, "输入与缓存只算一次")
    }

    func testOneHourCacheWritesCostTwicePrompt() {
        let rec = UsageRecord(timestamp: Date(), model: "m", inputTokens: 1_700, outputTokens: 10,
                              cacheReadTokens: 600, cacheWriteTokens: 1_000, cacheWrite1hTokens: 600, dedupKey: nil)
        // 固定费率：prompt 5、output 25、读缓存 0.5、写缓存（5 分钟档）6.25
        let price: (String, Int, Int, Int, Int) -> Double? = { _, input, output, read, write in
            Double(input) * 5 + Double(output) * 25 + Double(read) * 0.5 + Double(write) * 6.25
        }
        // 100 × 5 + 10 × 25 + 600 × 0.5 + 400 × 6.25 + 600 × 2 × 5
        XCTAssertEqual(JSONLUsageParser.cost(of: rec, price: price), 9_550)
        XCTAssertNil(JSONLUsageParser.cost(of: rec, price: { _, _, _, _, _ in nil }), "没定价就是没定价，不拿附加费凑一个数")
    }

    func testOneHourCacheWritesAreParsedFromClaudeUsage() {
        let line = #"{"timestamp":"2026-09-01T00:00:00Z","requestId":"r","message":{"id":"m","model":"claude-opus-5","usage":{"input_tokens":1,"cache_creation_input_tokens":900,"cache_creation":{"ephemeral_5m_input_tokens":300,"ephemeral_1h_input_tokens":600},"output_tokens":1}}}"#
        XCTAssertEqual(JSONLUsageParser.parseLine(line)?.cacheWrite1hTokens, 600)
    }

    func testCodexRepeatedTokenCountIsNotCountedTwice() throws {
        let now = Date()
        // 第二条是重复上报：累计值没动，last 却原样再报一次
        let text = #"{"type":"turn_context","payload":{"model":"gpt-6"}}"# + "\n"
            + codexCount(30, total: (100, 10), last: (100, 10), now: now)
            + codexCount(29, total: (100, 10), last: (100, 10), now: now)
            + codexCount(20, total: (250, 30), last: (150, 20), now: now)
        let url = try write(text, to: "x.jsonl")
        let week = UsageScanCache().aggregate(files: [url], now: now).week
        XCTAssertEqual(week.inputTokens, 250)
        XCTAssertEqual(week.outputTokens, 30)
    }

    func testCodexTotalsCarryAcrossIncrementalScanAndRelaunch() throws {
        let now = Date()
        let store = directory.appendingPathComponent("cache")
        let url = try write(codexCount(30, total: (100, 10), last: (100, 10), now: now), to: "x.jsonl")
        let first = UsageScanCache(name: "x", directory: store)
        XCTAssertEqual(first.aggregate(files: [url], now: now).week.inputTokens, 100)
        first.flush()

        // 重开 app 后续扫：差值要和盘上存的累计值相减，不能从 0 起算把整个累计值再记一遍
        _ = try write(codexCount(20, total: (250, 30), last: (150, 20), now: now), to: "x.jsonl", append: true)
        let second = UsageScanCache(name: "x", directory: store)
        XCTAssertEqual(second.aggregate(files: [url], now: now).week.inputTokens, 250)
    }

    func testCodexUnterminatedTailDoesNotAdvanceTotals() throws {
        let now = Date()
        let complete = codexCount(30, total: (100, 10), last: (100, 10), now: now)
        let partial = String(codexCount(20, total: (250, 30), last: (150, 20), now: now).dropLast())  // 结尾没有换行
        let url = try write(complete + partial, to: "x.jsonl")
        let cache = UsageScanCache()
        XCTAssertEqual(cache.aggregate(files: [url], now: now).week.inputTokens, 250, "半行算这一轮")
        // 补上换行后这行被当完整行重读：累计值没被半行推进过，差值仍是 150
        _ = try write("\n", to: "x.jsonl", append: true)
        XCTAssertEqual(cache.aggregate(files: [url], now: now).week.inputTokens, 250)
    }

    func testCodexOldFormatWithoutTotalsStillCounts() {
        let line = #"{"type":"event_msg","timestamp":"2026-09-01T00:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"output_tokens":250}}}}"#
        XCTAssertEqual(JSONLUsageParser.parseLine(line)?.inputTokens, 500)
    }
}
