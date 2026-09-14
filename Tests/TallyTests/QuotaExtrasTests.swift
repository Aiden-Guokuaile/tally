import XCTest
@testable import Tally

final class QuotaPaceTests: XCTestCase {

    func testElapsedFraction() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(try XCTUnwrap(QuotaPace.elapsedFraction(resetsAt: now.addingTimeInterval(3600), window: 5 * 3600, now: now)), 0.8, accuracy: 1e-9,
                       "5 小时窗口还剩 1 小时，过去了 80%")
        XCTAssertNil(QuotaPace.elapsedFraction(resetsAt: nil, window: 5 * 3600, now: now), "没有重置时间")
        XCTAssertNil(QuotaPace.elapsedFraction(resetsAt: now.addingTimeInterval(3600), window: nil, now: now), "窗口长度拿不准")
        XCTAssertNil(QuotaPace.elapsedFraction(resetsAt: now.addingTimeInterval(-1), window: 3600, now: now), "已过重置时间")
        XCTAssertNil(QuotaPace.elapsedFraction(resetsAt: now.addingTimeInterval(7200), window: 3600, now: now), "剩余比窗口还长，数据对不上")
    }

    func testAheadNeedsTenPoints() {
        XCTAssertTrue(QuotaPace.isAhead(used: 0.9, elapsed: 0.8), "正好领先 10 个百分点")
        XCTAssertFalse(QuotaPace.isAhead(used: 0.85, elapsed: 0.8))
        XCTAssertFalse(QuotaPace.isAhead(used: 0.3, elapsed: 0.6), "用得比时间慢")
    }

    func testOnlyClaudeAndCodexHaveWindows() {
        XCTAssertEqual(ProviderID.claude.limitWindows.session, 5 * 3600)
        XCTAssertEqual(ProviderID.codex.limitWindows.week, 7 * 86400)
        XCTAssertNil(ProviderID.cursor.limitWindows.session)
        XCTAssertNil(ProviderID.antigravity.limitWindows.week)
    }
}

final class QuotaAlertTrackerTests: XCTestCase {

    private let reset = Date(timeIntervalSince1970: 2_000_000)

    private func limit(_ fraction: Double, resetsAt: Date? = nil) -> UsageLimit {
        UsageLimit(used: fraction, limit: 1, resetsAt: resetsAt ?? reset)
    }

    func testFirstReadingNeverAlerts() {
        var tracker = QuotaAlertTracker()
        XCTAssertNil(tracker.feed(provider: .claude, window: "5 小时", limit: limit(0.95)), "开 app 时已经 95% 不补报")
        XCTAssertNil(tracker.feed(provider: .claude, window: "5 小时", limit: limit(0.96)))
    }

    func testCrossingEightyOnceAndExhaustedOnce() {
        var tracker = QuotaAlertTracker()
        _ = tracker.feed(provider: .codex, window: "7 天", limit: limit(0.5))
        XCTAssertEqual(tracker.feed(provider: .codex, window: "7 天", limit: limit(0.82))?.kind, .high(percent: 82))
        XCTAssertNil(tracker.feed(provider: .codex, window: "7 天", limit: limit(0.9)), "过了 80 之后不再报")
        XCTAssertEqual(tracker.feed(provider: .codex, window: "7 天", limit: limit(1))?.kind, .exhausted)
        XCTAssertNil(tracker.feed(provider: .codex, window: "7 天", limit: limit(1)))
    }

    func testJumpStraightToFullReportsOnlyExhausted() {
        var tracker = QuotaAlertTracker()
        _ = tracker.feed(provider: .claude, window: "5 小时", limit: limit(0.79))
        XCTAssertEqual(tracker.feed(provider: .claude, window: "5 小时", limit: limit(1))?.kind, .exhausted)
    }

    func testResetAlertsOnlyAfterHighUsage() {
        var tracker = QuotaAlertTracker()
        _ = tracker.feed(provider: .claude, window: "5 小时", limit: limit(0.85))
        let next = reset.addingTimeInterval(5 * 3600)
        XCTAssertEqual(tracker.feed(provider: .claude, window: "5 小时", limit: limit(0.02, resetsAt: next))?.kind, .reset, "重置时刻往后挪了一个窗口")
        XCTAssertNil(tracker.feed(provider: .claude, window: "5 小时", limit: limit(0.3, resetsAt: next.addingTimeInterval(120))), "几分钟的抖动不算重置")
        XCTAssertNil(tracker.feed(provider: .claude, window: "5 小时", limit: limit(0.05, resetsAt: next.addingTimeInterval(5 * 3600))), "没用过 80 的窗口重置不报")

        // 没有重置时刻的（Cursor）靠用量大跌认重置
        var cursor = QuotaAlertTracker()
        _ = cursor.feed(provider: .cursor, window: "Cursor", limit: UsageLimit(used: 0.9, limit: 1))
        XCTAssertEqual(cursor.feed(provider: .cursor, window: "Cursor", limit: UsageLimit(used: 0.1, limit: 1))?.kind, .reset)
    }

    func testWindowsTrackedSeparately() {
        var tracker = QuotaAlertTracker()
        _ = tracker.feed(provider: .claude, window: "5 小时", limit: limit(0.5))
        XCTAssertNil(tracker.feed(provider: .claude, window: "7 天", limit: limit(0.9)), "别的窗口是第一次读到")
        XCTAssertEqual(tracker.feed(provider: .claude, window: "5 小时", limit: limit(0.8))?.kind, .high(percent: 80))
    }
}

final class QuotaBackoffTests: XCTestCase {

    func testDelayDoublesUpToCapAndHonoursRetryAfter() {
        XCTAssertEqual(QuotaBackoff.nextDelay(previous: nil, retryAfter: nil), 60)
        XCTAssertEqual(QuotaBackoff.nextDelay(previous: 60, retryAfter: nil), 120)
        XCTAssertEqual(QuotaBackoff.nextDelay(previous: 600, retryAfter: nil), 900, "封顶 15 分钟")
        XCTAssertEqual(QuotaBackoff.nextDelay(previous: nil, retryAfter: 300), 300, "Retry-After 更长听它的")
        XCTAssertEqual(QuotaBackoff.nextDelay(previous: nil, retryAfter: 7200), 900, "Retry-After 也封顶")
    }

    func testThrottleBlocksUntilDeadlineAndSuccessClears() {
        let backoff = QuotaBackoff()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(backoff.allows("k", now: now))
        backoff.throttled("k", now: now, retryAfter: nil)
        XCTAssertFalse(backoff.allows("k", now: now.addingTimeInterval(59)))
        XCTAssertTrue(backoff.allows("k", now: now.addingTimeInterval(60)))
        XCTAssertTrue(backoff.allows("other", now: now), "按接口分开")
        backoff.throttled("k", now: now.addingTimeInterval(60), retryAfter: nil)
        XCTAssertFalse(backoff.allows("k", now: now.addingTimeInterval(179)), "第二次退 120 秒")
        backoff.succeeded("k")
        XCTAssertTrue(backoff.allows("k", now: now.addingTimeInterval(61)), "成功一次清零")
    }

    func testStatePersistsAcrossInstances() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tally-backoff-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let now = Date(timeIntervalSince1970: 5_000)
        QuotaBackoff(file: file).throttled("claude-oauth-usage", now: now, retryAfter: nil)
        XCTAssertFalse(QuotaBackoff(file: file).allows("claude-oauth-usage", now: now.addingTimeInterval(30)), "重开 app 还记得")
    }

    func testRetryAfterParsesSecondsOnly() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let seconds = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"]))
        let date = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]))
        XCTAssertEqual(QuotaBackoff.retryAfter(seconds), 120)
        XCTAssertNil(QuotaBackoff.retryAfter(date))
    }
}

/// 可以一轮一轮改读数的假提供方。
private final class SteppingProvider: UsageProvider, @unchecked Sendable {
    let id: ProviderID = .codex
    var fraction = 0.5
    var stale = false

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.sessionLimit = UsageLimit(used: fraction, limit: 1, resetsAt: now.addingTimeInterval(3600))
        snapshot.limitsStale = stale
        return snapshot
    }
}

final class UsageStoreWakeAndAlertTests: XCTestCase {

    @MainActor
    func testRefreshesAreHeldForAMinuteAfterWake() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let store = UsageStore(providers: [SteppingProvider()], clock: { now }, preferences: { Preferences() })
        store.providersChanged()
        store.systemDidWake()
        let held = await store.refreshAndWait(reason: .panelOpened)
        XCTAssertFalse(held, "睡醒 60 秒内不拉")
        now = now.addingTimeInterval(UsageStore.wakeGrace)
        let allowed = await store.refreshAndWait(reason: .panelOpened)
        XCTAssertTrue(allowed)
    }

    @MainActor
    func testFreshReadingsFeedQuotaAlertsButStaleOnesDoNot() async {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let provider = SteppingProvider()
        let store = UsageStore(providers: [provider], clock: { now }, preferences: { Preferences() })
        var events: [QuotaEvent] = []
        store.quotaAlert = { events.append($0) }
        store.providersChanged()
        _ = await store.refreshAndWait(reason: .timer)

        provider.fraction = 0.85
        provider.stale = true
        now = now.addingTimeInterval(61)
        _ = await store.refreshAndWait(reason: .timer)
        XCTAssertTrue(events.isEmpty, "陈旧读数不喂")

        provider.stale = false
        now = now.addingTimeInterval(61)
        _ = await store.refreshAndWait(reason: .timer)
        XCTAssertEqual(events.map(\.kind), [.high(percent: 85)])
        XCTAssertEqual(events.first?.window, "5 小时")
    }
}
