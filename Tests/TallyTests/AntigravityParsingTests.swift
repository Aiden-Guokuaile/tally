import XCTest
@testable import Tally

/// Antigravity 两条配额各是一个池：第一条「Gemini 池」、第二条「Claude 池」（见 `ProviderID.limitLabels`）。
final class AntigravityParsingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func summary(_ buckets: [(String, Double)]) -> Data {
        let rows = buckets.map { #"{"bucketId":"\#($0.0)","remainingFraction":\#($0.1),"resetTime":"2026-09-12T00:00:00Z"}"# }
        return Data(#"{"response":{"groups":[{"buckets":[\#(rows.joined(separator: ","))]}]}}"#.utf8)
    }

    func testSummaryPutsEachPoolInItsOwnBar() throws {
        // Gemini 两个窗口都很宽裕，Claude 池（3p）周窗口快用光了
        let snapshot = try XCTUnwrap(AntigravityUsageProvider.parseQuotaSummary(
            summary([("gemini-5h", 1.0), ("gemini-weekly", 0.95), ("3p-5h", 0.8), ("3p-weekly", 0.1)]), now: now))
        XCTAssertEqual(snapshot.sessionLimit?.used ?? -1, 5, accuracy: 0.001, "Gemini 池取剩得少的周窗口")
        XCTAssertEqual(snapshot.weekLimit?.used ?? -1, 90, accuracy: 0.001, "标「Claude 池」的那条必须是 3p 的，不是 gemini 的周窗口")
    }

    func testSummaryWithOnlyOnePoolLeavesTheOtherEmpty() throws {
        let snapshot = try XCTUnwrap(AntigravityUsageProvider.parseQuotaSummary(summary([("gemini-5h", 0.5)]), now: now))
        XCTAssertEqual(snapshot.sessionLimit?.used ?? -1, 50, accuracy: 0.001)
        XCTAssertNil(snapshot.weekLimit)
    }

    func testSummaryWithoutAnyKnownBucketIsNotAReading() {
        // 返回 nil 调用方才会接着问下一个端点；返回一个空快照的话搜索就停在这儿，界面只剩个名字
        XCTAssertNil(AntigravityUsageProvider.parseQuotaSummary(summary([("something-new", 0.3)]), now: now))
        XCTAssertNil(AntigravityUsageProvider.parseQuotaSummary(Data(#"{"response":{"groups":[]}}"#.utf8), now: now))
    }

    func testModelWithoutQuotaInfoIsNotReadAsSpent() {
        XCTAssertNil(AntigravityUsageProvider.parseModelConfig(["label": "Gemini 3.7 Pro"]), "没有 quotaInfo 是没读数，不是用光了")
        // 有 quotaInfo 而缺 remainingFraction：proto3 的 JSON 不写零值，这才是剩 0
        XCTAssertEqual(AntigravityUsageProvider.parseModelConfig(["label": "Gemini 3.7 Pro", "quotaInfo": [String: Any]()])?.remainingFraction, 0)
        XCTAssertEqual(AntigravityUsageProvider.parseModelConfig(["label": "Claude", "quotaInfo": ["remainingFraction": 0.4]])?.remainingFraction, 0.4)
    }

    func testModelConfigPoolsGoToTheirOwnBars() throws {
        let configs = [
            AntigravityModelConfig(label: "Claude Sonnet 5 (Thinking)", modelID: nil, remainingFraction: 0.6, resetTime: nil),
            AntigravityModelConfig(label: "GPT-OSS 200B", modelID: nil, remainingFraction: 0.9, resetTime: nil),
        ]
        let claudeOnly = try XCTUnwrap(AntigravityUsageProvider.buildSnapshot(from: configs, now: now))
        XCTAssertNil(claudeOnly.sessionLimit, "没有 Gemini 模型就不画 Gemini 池，更不能把 Claude 池塞进那条")
        XCTAssertEqual(claudeOnly.weekLimit?.used ?? -1, 40, accuracy: 0.001)

        let untouched = try XCTUnwrap(AntigravityUsageProvider.buildSnapshot(
            from: [AntigravityModelConfig(label: "Gemini 3.7 Flash", modelID: nil, remainingFraction: 1, resetTime: nil)], now: now))
        XCTAssertEqual(untouched.sessionLimit?.used, 0, "没用过也是读数：0%")

        XCTAssertNil(AntigravityUsageProvider.buildSnapshot(from: [], now: now), "一条配置都没有就接着找")
    }
}
