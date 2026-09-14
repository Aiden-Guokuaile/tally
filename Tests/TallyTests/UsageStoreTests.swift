import XCTest
@testable import Tally

/// 假提供方：返回固定结果或抛错。
private struct FakeProvider: UsageProvider {
    let id: ProviderID
    let error: String?

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        if let error { throw UsageError.notFound(error) }
        var snapshot = UsageSnapshot()
        snapshot.sessionLimit = UsageLimit(used: 0.5, limit: 1)
        snapshot.lastUpdated = now
        return snapshot
    }
}

/// 可拨的时钟和可改的开关，给 UsageStore 注入。
@MainActor
private final class Harness {
    var now = Date(timeIntervalSince1970: 1_000_000)
    var prefs = Preferences()
    let store: UsageStore

    init(providers: [UsageProvider]) {
        var clockBox: (() -> Date)!
        var prefsBox: (() -> Preferences)!
        store = UsageStore(providers: providers, clock: { clockBox() }, preferences: { prefsBox() })
        clockBox = { [unowned self] in self.now }
        prefsBox = { [unowned self] in self.prefs }
    }
}

final class UsageStoreTests: XCTestCase {

    @MainActor
    func testSecondRefreshWithinSixtySecondsIsSkippedAndDoesNotResetClock() async {
        let h = Harness(providers: [FakeProvider(id: .claude, error: nil)])
        h.store.providersChanged()
        let first = await h.store.refreshAndWait(reason: .panelOpened)
        XCTAssertTrue(first)
        h.now = h.now.addingTimeInterval(20)
        let second = await h.store.refreshAndWait(reason: .manual)
        XCTAssertFalse(second)
        // 被跳过的那次不重置计时：从第一次算起 60 秒后才放行
        h.now = h.now.addingTimeInterval(41)
        let third = await h.store.refreshAndWait(reason: .timer)
        XCTAssertTrue(third)
    }

    @MainActor
    func testOneProviderFailingDoesNotAffectAnother() async {
        let h = Harness(providers: [FakeProvider(id: .claude, error: nil), FakeProvider(id: .codex, error: "boom")])
        h.store.providersChanged()
        _ = await h.store.refreshAndWait(reason: .timer)
        guard case .success? = h.store.results[.claude] else { return XCTFail("claude 应成功") }
        guard case .failure(let message)? = h.store.results[.codex] else { return XCTFail("codex 应失败") }
        XCTAssertEqual(message, "boom")
    }

    @MainActor
    func testProvidersChangedDropsDisabledAndMarksNewAsLoading() async throws {
        let h = Harness(providers: [FakeProvider(id: .claude, error: nil), FakeProvider(id: .cursor, error: nil)])
        h.store.providersChanged()
        _ = await h.store.refreshAndWait(reason: .timer)
        XCTAssertNotNil(h.store.results[.cursor])

        h.prefs.enableCursor = false
        h.store.providersChanged()
        XCTAssertNil(h.store.results[.cursor])
        guard case .success? = h.store.results[.claude] else { return XCTFail("claude 结果应保留") }

        h.prefs.enableCursor = true
        h.store.providersChanged()
        guard case .loading? = h.store.results[.cursor] else { return XCTFail("新开启的应为 loading") }
        // 紧接着那一家会单独刷一次；等它跑完再结束，别让后台任务读到已经释放的 Harness
        try await Task.sleep(nanoseconds: 50_000_000)
        guard case .success? = h.store.results[.cursor] else { return XCTFail("单独刷完应有结果") }
    }

    @MainActor
    func testStuckPassStopsBlockingAfterCeiling() async throws {
        let gated = GatedProvider(id: .claude)
        let h = Harness(providers: [gated])
        h.store.providersChanged()
        XCTAssertTrue(h.store.refresh(reason: .timer))
        h.now = h.now.addingTimeInterval(100)
        XCTAssertFalse(h.store.refresh(reason: .timer), "一轮还没回来，上限之内不叠第二轮")
        h.now = h.now.addingTimeInterval(81)
        XCTAssertTrue(h.store.refresh(reason: .timer), "卡满 180 秒就放行：一家卡住不能拖着四家一起停")
        // 等两轮都真正跑起来、把卡住的那轮放掉再结束，别让后台任务读到已经释放的 Harness
        try await Task.sleep(nanoseconds: 50_000_000)
        gated.release()
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    @MainActor
    func testLateResultOfAbandonedPassIsDropped() async throws {
        let gated = GatedProvider(id: .claude)
        let h = Harness(providers: [gated])
        h.store.providersChanged()
        XCTAssertTrue(h.store.refresh(reason: .timer))          // 第一轮：卡住
        try await Task.sleep(nanoseconds: 50_000_000)
        h.now = h.now.addingTimeInterval(181)
        let second = await h.store.refreshAndWait(reason: .timer)  // 第二轮：拿到了
        XCTAssertTrue(second)
        gated.release()                                          // 第一轮这才迟迟失败回来
        try await Task.sleep(nanoseconds: 50_000_000)
        guard case .success(let snapshot)? = h.store.results[.claude] else { return XCTFail("迟到的失败不许盖掉新一轮的成功") }
        XCTAssertFalse(snapshot.limitsStale)
        XCTAssertNil(snapshot.limitsNote)
        XCTAssertFalse(h.store.isRefreshing)
    }

    @MainActor
    func testEnablingAProviderFetchesItRightAway() async throws {
        let h = Harness(providers: [FakeProvider(id: .claude, error: nil), FakeProvider(id: .cursor, error: nil)])
        h.prefs.enableCursor = false
        h.store.providersChanged()
        _ = await h.store.refreshAndWait(reason: .timer)
        h.prefs.enableCursor = true
        h.store.providersChanged()
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .success? = h.store.results[.cursor] else { return XCTFail("新开的那家不该「加载中」等到下一轮刷新") }
    }

    // MARK: 临时失败沿用上一轮的配额

    func testCarryOverKeepsLastLiveLimitsOnTransientFailure() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let live = UsageStore.LiveLimits(session: UsageLimit(used: 30, limit: 100, resetsAt: now.addingTimeInterval(3600)),
                                         week: UsageLimit(used: 60, limit: 100, resetsAt: now.addingTimeInterval(-60)),
                                         at: now.addingTimeInterval(-600))
        // 成功但两条配额都是 nil（Codex 断网那种）：沿用并标「~」，费用用这一轮的
        var fresh = UsageSnapshot()
        fresh.week.costUSD = 3
        guard case .success(let carried) = UsageStore.carryOver(.success(fresh), previous: nil, live: live, now: now) else { return XCTFail() }
        XCTAssertEqual(carried.sessionLimit?.used, 30)
        XCTAssertNil(carried.weekLimit, "已过重置时间的窗口不沿用")
        XCTAssertTrue(carried.limitsStale)
        XCTAssertEqual(carried.week.costUSD, 3)

        // 失败（Cursor 一次 429）：拿上一轮的快照，错误文本当提示，不再只剩一行红字
        var last = UsageSnapshot()
        last.sessionLimit = UsageLimit(used: 30, limit: 100)
        guard case .success(let kept) = UsageStore.carryOver(.failure("Cursor quota unavailable"), previous: .success(last), live: live, now: now)
        else { return XCTFail() }
        XCTAssertEqual(kept.limitsNote, "Cursor quota unavailable")
        XCTAssertTrue(kept.limitsStale)
        XCTAssertEqual(kept.sessionLimit?.used, 30)
    }

    func testLongCarryOverSaysSoInTheRow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func carried(ageMinutes: Double, result: UsageResult = .success(UsageSnapshot())) -> String? {
            let live = UsageStore.LiveLimits(session: UsageLimit(used: 30, limit: 100), week: nil, at: now.addingTimeInterval(-ageMinutes * 60))
            guard case .success(let s) = UsageStore.carryOver(result, previous: .success(UsageSnapshot()), live: live, now: now) else { return "not carried" }
            return s.limitsNote
        }
        XCTAssertNil(carried(ageMinutes: 10), "一两次失败只标「~」，不值得红字")
        XCTAssertEqual(carried(ageMinutes: 45), "配额已 45 分钟没更新", "一直读不到（接口改版、登录失效）得让人知道")
        XCTAssertEqual(carried(ageMinutes: 190), "配额已 3 小时没更新")
        XCTAssertEqual(carried(ageMinutes: 190, result: .failure("Cursor quota unavailable")), "Cursor quota unavailable", "有真实错误就说真实错误")
    }

    func testCarryOverGivesUpWhenNothingIsCurrent() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let allReset = UsageStore.LiveLimits(session: UsageLimit(used: 90, limit: 100, resetsAt: now.addingTimeInterval(-1)), week: nil,
                                             at: now.addingTimeInterval(-600))
        guard case .failure = UsageStore.carryOver(.failure("x"), previous: .success(UsageSnapshot()), live: allReset, now: now) else {
            return XCTFail("窗口全都重置了，照实显示失败")
        }
        let tooOld = UsageStore.LiveLimits(session: UsageLimit(used: 10, limit: 100), week: nil, at: now.addingTimeInterval(-25 * 3600))
        guard case .failure = UsageStore.carryOver(.failure("x"), previous: .success(UsageSnapshot()), live: tooOld, now: now) else {
            return XCTFail("超过 24 小时不沿用")
        }
        guard case .failure = UsageStore.carryOver(.failure("x"), previous: .loading, live: tooOld, now: now) else { return XCTFail() }
        // 这一轮拿到了配额就原样用这一轮的
        var got = UsageSnapshot()
        got.weekLimit = UsageLimit(used: 5, limit: 100)
        let recent = UsageStore.LiveLimits(session: UsageLimit(used: 10, limit: 100), week: nil, at: now)
        guard case .success(let used) = UsageStore.carryOver(.success(got), previous: nil, live: recent, now: now) else { return XCTFail() }
        XCTAssertEqual(used.weekLimit?.used, 5)
        XCTAssertNil(used.sessionLimit)
        XCTAssertFalse(used.limitsStale)
    }
}

/// 第一次调用卡住，直到 `release()` 才以失败返回；之后的调用立刻成功。模拟「某家卡在一个没人点的系统框上」。
private final class GatedProvider: UsageProvider, @unchecked Sendable {
    let id: ProviderID
    private let lock = NSLock()
    private var calls = 0
    private var parked: [CheckedContinuation<Void, Never>] = []

    init(id: ProviderID) { self.id = id }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        if call == 1 {
            await withCheckedContinuation { continuation in lock.withLock { parked.append(continuation) } }
            throw UsageError.notFound("late")
        }
        var snapshot = UsageSnapshot()
        snapshot.sessionLimit = UsageLimit(used: 10, limit: 100)
        return snapshot
    }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { parked = [] }
            return parked
        }
        waiting.forEach { $0.resume() }
    }
}

final class TokenFormatTests: XCTestCase {
    func testShort() {
        XCTAssertEqual(TokenFormat.short(0), "0")
        XCTAssertEqual(TokenFormat.short(999), "999")
        XCTAssertEqual(TokenFormat.short(1_000), "1k")
        XCTAssertEqual(TokenFormat.short(1_234), "1.2k")
        XCTAssertEqual(TokenFormat.short(24_100_000), "24.1M")
        XCTAssertEqual(TokenFormat.short(312_000_000), "312M")
        XCTAssertEqual(TokenFormat.short(2_400_000_000), "2.4B")
        XCTAssertEqual(TokenFormat.short(-5), "0", "负数当 0")
    }

    func testRoundingUpCarriesIntoTheNextUnit() {
        XCTAssertEqual(TokenFormat.short(999_949), "999.9k")
        XCTAssertEqual(TokenFormat.short(999_950), "1M", "舍入到 1000.0k 就该写成 1M，不是「1000k」")
        XCTAssertEqual(TokenFormat.short(999_950_000), "1B")
    }
}

final class ClaudeTokenBoxTests: XCTestCase {
    func testReadsKeychainOnceAndBacksOffOnFailure() {
        var reads = 0
        let missing = URL(fileURLWithPath: "/nonexistent/.credentials.json")
        let payload = #"{"claudeAiOauth":{"accessToken":"abc","expiresAt":\#(Int(Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000))}}"#
        let client = ClaudeQuotaReadOnly(credentialsFile: missing, keychainItem: { reads += 1; return payload })
        let now = Date()
        XCTAssertEqual(client.loadToken(now: now)?.accessToken, "abc")
        XCTAssertEqual(reads, 1)
        _ = client.loadToken(now: now.addingTimeInterval(300))
        _ = client.loadToken(now: now.addingTimeInterval(3000))
        XCTAssertEqual(reads, 1, "一个进程只读一次钥匙串，不然每轮刷新都弹授权框")

        // token 过期：扔掉重读一次
        client.tokenBox.clear()
        _ = client.loadToken(now: now.addingTimeInterval(4000))
        XCTAssertEqual(reads, 2)
    }

    func testFailedReadIsNotRetriedEveryRefresh() {
        var reads = 0
        let missing = URL(fileURLWithPath: "/nonexistent/.credentials.json")
        let client = ClaudeQuotaReadOnly(credentialsFile: missing, keychainItem: { reads += 1; return nil })
        let now = Date()
        XCTAssertNil(client.loadToken(now: now))
        XCTAssertEqual(reads, 1)
        XCTAssertNil(client.loadToken(now: now.addingTimeInterval(300)))
        XCTAssertEqual(reads, 1, "用户点了取消之后，10 分钟内不再弹")
        XCTAssertNil(client.loadToken(now: now.addingTimeInterval(700)))
        XCTAssertEqual(reads, 2, "过了冷却期再试一次")
    }
}
