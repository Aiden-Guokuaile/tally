import XCTest
@testable import Tally

final class TranscriptTitleTests: XCTestCase {

    private func titleLine(_ title: String) -> String {
        let escaped = title.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"type\":\"ai-title\",\"aiTitle\":\"\(escaped)\",\"sessionId\":\"s\"}"
    }

    private func customLine(_ title: String) -> String {
        "{\"type\":\"custom-title\",\"customTitle\":\"\(title)\",\"sessionId\":\"s\"}"
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-title-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func tempFile(_ content: String, in dir: URL? = nil) throws -> URL {
        let url = try (dir ?? tempDir()).appendingPathComponent("t.jsonl")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTakesLastTitleInTail() throws {
        let url = try tempFile([titleLine("旧"), "{\"type\":\"user\"}", titleLine("新"), "{\"type\":\"assistant\"}"].joined(separator: "\n") + "\n")
        XCTAssertEqual(TranscriptTitle.read(from: url, sessionId: "s"), "新")
    }

    func testCustomTitleRecordWins() throws {
        let url = try tempFile([titleLine("自动"), customLine("我改的"), "{\"type\":\"user\"}"].joined(separator: "\n") + "\n")
        XCTAssertEqual(TranscriptTitle.read(from: url, sessionId: "s"), "我改的")
    }

    func testSidecarBeatsTail() throws {
        let dir = try tempDir()
        let url = try tempFile(titleLine("文件尾") + "\n", in: dir)
        let sidecarDir = dir.appendingPathComponent("s")
        try FileManager.default.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
        try #"{"customTitle":"边车"}"#.write(to: sidecarDir.appendingPathComponent("custom-title.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptTitle.read(from: url, sessionId: "s"), "边车")
        XCTAssertEqual(TranscriptTitle.read(from: url, sessionId: "other"), "文件尾")
    }

    func testNoTitleOrMissingFileIsNil() throws {
        let url = try tempFile("{\"type\":\"user\"}\n")
        XCTAssertNil(TranscriptTitle.read(from: url, sessionId: "s"))
        XCTAssertNil(TranscriptTitle.read(from: URL(fileURLWithPath: "/nonexistent/x.jsonl"), sessionId: "s"))
    }

    func testTruncatedFirstLineIsDropped() throws {
        // 第一行超过 64 KB，切口落在它中间；尾部有真标题。
        let huge = titleLine("假" + String(repeating: "x", count: 70 * 1024))
        let url = try tempFile(huge + "\n{\"type\":\"user\"}\n" + titleLine("真") + "\n")
        XCTAssertEqual(TranscriptTitle.readTail(from: url), "真")
    }

    func testTruncatedFirstLineWithoutLaterTitleIsNilButFullScanFindsIt() throws {
        let huge = titleLine("假" + String(repeating: "x", count: 70 * 1024))
        let url = try tempFile(titleLine("开头的") + "\n" + huge + "\n{\"type\":\"user\"}\n")
        XCTAssertNil(TranscriptTitle.readTail(from: url))
        XCTAssertEqual(TranscriptTitle.readFull(from: url), "假" + String(repeating: "x", count: 70 * 1024))
    }

    func testBlankTitleIgnoredAndTrimmed() {
        XCTAssertNil(TranscriptTitle.parse(titleLine("   ") + "\n", truncated: false))
        XCTAssertEqual(TranscriptTitle.parse(titleLine(" 有 ") + "\n", truncated: false), "有")
    }

    // ── 回合怎么结束的 ─────────────────────────────────────────

    private let prompt = #"{"type":"user","message":{"role":"user","content":"跑一下"}}"#
    private let reply = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"好"}],"stop_reason":"end_turn"}}"#
    private let interrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    private let apiError = #"{"type":"assistant","isApiErrorMessage":true,"error":"rate_limit","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 3pm"}]}}"#
    private let snapshot = #"{"type":"file-history-snapshot","messageId":"m","snapshot":{}}"#

    private func turnEnd(_ lines: [String]) -> TranscriptTitle.TurnEnd? {
        TranscriptTitle.parseTurnEnd(lines.joined(separator: "\n") + "\n", truncated: false)
    }

    func testInterruptEndsTurnInBothWordingsAndWithRecordsAppendedAfter() {
        XCTAssertEqual(turnEnd([prompt, reply, interrupt]), .interrupted)
        let toolUse = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
        let mode = #"{"type":"permission-mode","permissionMode":"default"}"#
        let local = #"{"type":"system","subtype":"local_command","content":"<local-command-stdout>ok</local-command-stdout>"}"#
        XCTAssertEqual(turnEnd([prompt, toolUse, snapshot, mode, local]), .interrupted, "打断后追加的快照、模式、本地命令记录跳过")
        XCTAssertEqual(turnEnd([prompt, #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"#]), .interrupted, "正文是字符串的写法")
    }

    func testApiErrorEndsTurnWithItsText() {
        XCTAssertEqual(turnEnd([prompt, apiError, snapshot]), .apiError("You've hit your session limit · resets 3pm"))
    }

    func testTurnStillGoingIsNil() {
        XCTAssertNil(turnEnd([prompt]), "刚发出去")
        XCTAssertNil(turnEnd([prompt, reply]), "正常回复完靠 Stop，不归这里")
        XCTAssertNil(turnEnd([prompt, interrupt, prompt]), "打断后又发了一句")
        let queued = #"{"type":"attachment","attachment":{"type":"queued_command","prompt":"再试"}}"#
        XCTAssertNil(turnEnd([prompt, apiError, queued, reply]), "报错后排队的输入接着跑")
        XCTAssertNil(turnEnd([snapshot]), "尾巴里没有对话记录")
    }

    func testSidechainAndMetaRecordsAreSkipped() {
        let sidechain = #"{"type":"user","isSidechain":true,"message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        XCTAssertNil(turnEnd([prompt, reply, sidechain]), "子 agent 被打断不等于主回合结束")
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"Continue from where you left off."}}"#
        XCTAssertEqual(turnEnd([prompt, apiError, meta]), .apiError("You've hit your session limit · resets 3pm"), "注入的提示不算新输入")
    }

    func testTurnEndReadsFileTail() throws {
        XCTAssertEqual(TranscriptTitle.turnEnd(in: try tempFile([prompt, interrupt].joined(separator: "\n") + "\n")), .interrupted)
        XCTAssertNil(TranscriptTitle.turnEnd(in: URL(fileURLWithPath: "/nonexistent/x.jsonl")))
    }
}
