import XCTest
@testable import Tally

/// 假的 URLProtocol：记请求次数，按预设返回。
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ClaudeQuotaReadOnlyTests: XCTestCase {

    private var dir: URL!
    private let sample = #"{"five_hour":{"utilization":23.5,"resets_at":"2026-09-08T13:20:00Z"},"seven_day":{"utilization":31.0,"resets_at":"2026-09-11T06:00:00+08:00"}}"#

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-quota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        StubURLProtocol.requests = []
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data(sample.utf8)
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func credentials(expiresAt: Double?) throws -> URL {
        let file = dir.appendingPathComponent(".credentials.json")
        var oauth: [String: Any] = ["accessToken": "tok-123", "refreshToken": "never-read"]
        if let expiresAt { oauth["expiresAt"] = expiresAt }
        try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]).write(to: file)
        return file
    }

    private func sha(_ url: URL) throws -> Int {
        try Data(contentsOf: url).hashValue
    }

    func testExpiredTokenSendsNoRequest() async throws {
        let file = try credentials(expiresAt: 1_000_000 * 1000)
        let client = ClaudeQuotaReadOnly(session: session(), credentialsFile: file, keychainItem: { nil })
        let result = await client.fetch(now: Date(timeIntervalSince1970: 1_000_001))
        XCTAssertEqual(result, .tokenExpired)
        XCTAssertEqual(StubURLProtocol.requests.count, 0)
    }

    func testSampleResponseParsesBothWindows() async throws {
        let file = try credentials(expiresAt: nil)
        let before = try sha(file)
        let client = ClaudeQuotaReadOnly(session: session(), credentialsFile: file, keychainItem: { nil })
        guard case .limits(let limits) = await client.fetch(now: Date(timeIntervalSince1970: 1_000_000)) else { return XCTFail() }
        XCTAssertEqual(limits.session?.used, 23.5)
        XCTAssertEqual(limits.session?.limit, 100)
        XCTAssertEqual(limits.session?.resetsAt, ClaudeQuotaReadOnly.parseDate("2026-09-08T13:20:00Z"))
        XCTAssertEqual(limits.week?.used, 31.0)
        XCTAssertNotNil(limits.week?.resetsAt)
        XCTAssertFalse(limits.isStale)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
        XCTAssertEqual(try sha(file), before, "凭据文件一个字节都不能动")
    }

    func testUnauthorizedIsTokenExpiredWithExactlyOneRequest() async throws {
        StubURLProtocol.status = 401
        let file = try credentials(expiresAt: nil)
        let client = ClaudeQuotaReadOnly(session: session(), credentialsFile: file, keychainItem: { nil })
        let result = await client.fetch()
        XCTAssertEqual(result, .tokenExpired)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testKeychainFallbackAndNoTokenIsUnavailable() async throws {
        let missing = dir.appendingPathComponent("nope.json")
        let fromKeychain = ClaudeQuotaReadOnly(session: session(), credentialsFile: missing, keychainItem: {
            #"{"claudeAiOauth":{"accessToken":"kc-1"}}"#
        })
        guard case .limits = await fromKeychain.fetch() else { return XCTFail("钥匙串里的 token 应可用") }
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer kc-1")

        let none = ClaudeQuotaReadOnly(session: session(), credentialsFile: missing, keychainItem: { nil })
        let result = await none.fetch()
        XCTAssertEqual(result, .unavailable)
    }

    func testServerErrorAndEmptyBodyAreUnavailable() async throws {
        let file = try credentials(expiresAt: nil)
        StubURLProtocol.status = 500
        let client = ClaudeQuotaReadOnly(session: session(), credentialsFile: file, keychainItem: { nil })
        let r1 = await client.fetch()
        XCTAssertEqual(r1, .unavailable)
        StubURLProtocol.status = 200
        StubURLProtocol.body = Data("{}".utf8)
        let r2 = await client.fetch()
        XCTAssertEqual(r2, .unavailable)
    }

    // provider 的三段顺序

    func testProviderPrefersFreshCache() {
        let cache = ClaudeLimits(session: UsageLimit(used: 0.2, limit: 1), week: nil, isStale: false)
        XCTAssertTrue(ClaudeUsageProvider.cacheIsFresh(cache))
        XCTAssertFalse(ClaudeUsageProvider.cacheIsFresh(nil))
        XCTAssertFalse(ClaudeUsageProvider.cacheIsFresh(ClaudeLimits(session: nil, week: nil, isStale: true)))
        // 缓存新鲜时 live 传 nil（根本没问接口），两条仍从缓存来
        let r = ClaudeUsageProvider.resolveLimits(cache: cache, live: nil, now: Date())
        XCTAssertEqual(r.session?.used, 0.2)
        XCTAssertFalse(r.stale)
        XCTAssertNil(r.note)
    }

    func testProviderNotesExpiryAndFallsBackToStaleCache() {
        let stale = ClaudeLimits(session: UsageLimit(used: 0.5, limit: 1), week: nil, isStale: true)
        let r = ClaudeUsageProvider.resolveLimits(cache: stale, live: .tokenExpired, now: Date())
        XCTAssertEqual(r.session?.used, 0.5)
        XCTAssertTrue(r.stale)
        XCTAssertEqual(r.note, "登录已过期，去 Claude Code 跑一轮")
    }

    func testProviderUsesLiveWhenCacheStaleAndNilWhenNothing() {
        let live = ClaudeLimits(session: UsageLimit(used: 40, limit: 100), week: nil, isStale: false)
        let r1 = ClaudeUsageProvider.resolveLimits(cache: nil, live: .limits(live), now: Date())
        XCTAssertEqual(r1.session?.used, 40)
        XCTAssertFalse(r1.stale)
        let r2 = ClaudeUsageProvider.resolveLimits(cache: nil, live: .unavailable, now: Date())
        XCTAssertNil(r2.session)
        XCTAssertNil(r2.week)
        XCTAssertFalse(r2.stale)
        XCTAssertNil(r2.note)
    }

    func testStaleFallbackDropsWindowsPastTheirReset() {
        // 隔夜：缓存里还是昨天 92% 的 5 小时窗口，早就重置了；token 也过期了
        let now = Date(timeIntervalSince1970: 2_000_000)
        let stale = ClaudeLimits(session: UsageLimit(used: 92, limit: 100, resetsAt: now.addingTimeInterval(-3600)),
                                 week: UsageLimit(used: 40, limit: 100, resetsAt: now.addingTimeInterval(86400)), isStale: true)
        let r = ClaudeUsageProvider.resolveLimits(cache: stale, live: .tokenExpired, now: now)
        XCTAssertNil(r.session, "已重置的窗口不能拿旧百分比充数")
        XCTAssertEqual(r.week?.used, 40, "还没重置的照常沿用")
        XCTAssertEqual(r.note, "登录已过期，去 Claude Code 跑一轮")
        // 新鲜缓存里刚好过了重置点的那条也一样
        let fresh = ClaudeLimits(session: UsageLimit(used: 99, limit: 100, resetsAt: now), week: nil, isStale: false)
        XCTAssertNil(ClaudeUsageProvider.resolveLimits(cache: fresh, live: nil, now: now).session)
    }

    func testExpiredCredentialsFileFallsBackToKeychain() async throws {
        // 新版 Claude Code 只写钥匙串：残留的旧文件里 token 早过期，先认它就一直报「登录已过期」
        let file = try credentials(expiresAt: 1_000_000 * 1000)
        let client = ClaudeQuotaReadOnly(session: session(), credentialsFile: file, keychainItem: {
            #"{"claudeAiOauth":{"accessToken":"kc-fresh","expiresAt":9999999999999}}"#
        })
        guard case .limits = await client.fetch(now: Date(timeIntervalSince1970: 1_000_001)) else { return XCTFail("应该用钥匙串里没过期的 token") }
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer kc-fresh")
    }

    // 按模型分的周窗口（Fable）

    func testParsesScopedWeeklyLimits() throws {
        let json = """
        {"five_hour":{"utilization":72.0,"resets_at":"2026-09-09T05:50:00.267100+00:00"},
         "seven_day":{"utilization":61.0,"resets_at":"2026-09-10T22:00:00.267122+00:00"},
         "seven_day_opus":null,"seven_day_sonnet":null,
         "limits":[
           {"kind":"session","group":"session","percent":72,"resets_at":"2026-09-09T05:50:00.267100+00:00","scope":null},
           {"kind":"weekly_all","group":"weekly","percent":61,"resets_at":"2026-09-10T22:00:00.267122+00:00","scope":null},
           {"kind":"weekly_scoped","group":"weekly","percent":100,"severity":"critical",
            "resets_at":"2026-09-10T22:00:00.267350+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}
        """
        let limits = try XCTUnwrap(ClaudeQuotaReadOnly.parseUsage(Data(json.utf8)))
        XCTAssertEqual(limits.session?.fraction ?? 0, 0.72, accuracy: 0.001)
        XCTAssertEqual(limits.scoped.count, 1, "只取 weekly_scoped，session 与 weekly_all 已经有专门的字段")
        XCTAssertEqual(limits.scoped.first?.label, "Fable")
        XCTAssertEqual(limits.scoped.first?.limit.fraction ?? 0, 1.0, accuracy: 0.001)
        XCTAssertNotNil(limits.scoped.first?.limit.resetsAt)
    }

    func testScopedIgnoresNullTopLevelFieldsAndMissingArray() {
        XCTAssertTrue(ClaudeQuotaReadOnly.scopedLimits(from: ["seven_day_opus": NSNull()]).isEmpty, "顶层那几个恒为 null，不当数据")
        XCTAssertTrue(ClaudeQuotaReadOnly.scopedLimits(from: [:]).isEmpty)
        XCTAssertTrue(ClaudeQuotaReadOnly.scopedLimits(from: ["limits": [["kind": "weekly_scoped", "percent": 50]]]).isEmpty, "没有 scope.model.display_name 不要")
    }

    func testScopedBoxThrottlesSuccessAndRetriesFailureSooner() {
        let box = ClaudeUsageProvider.ScopedLimitsBox()
        let now = Date()
        XCTAssertTrue(box.needsFetch(now: now), "第一次总要取")
        box.record([ScopedLimit(label: "Fable", limit: UsageLimit(used: 100, limit: 100))], now: now)
        XCTAssertFalse(box.needsFetch(now: now.addingTimeInterval(599)), "取到了隔 10 分钟再取")
        XCTAssertTrue(box.needsFetch(now: now.addingTimeInterval(601)))
        XCTAssertEqual(box.current.first?.label, "Fable")
        // 没拿到也要记时间（免得 token 过期后每次刷新都读凭据），但只隔 1 分钟——代理偶发断连不该让这条消失十分钟
        let failedAt = now.addingTimeInterval(601)
        box.record(nil, now: failedAt)
        XCTAssertFalse(box.needsFetch(now: failedAt.addingTimeInterval(59)))
        XCTAssertTrue(box.needsFetch(now: failedAt.addingTimeInterval(61)))
        XCTAssertEqual(box.current.first?.label, "Fable", "取失败沿用上一次的值")
    }

    func testScopedUpdateCallbackOnlyOnSuccess() {
        let box = ClaudeUsageProvider.ScopedLimitsBox()
        var got: [[ScopedLimit]] = []
        box.setOnUpdate { got.append($0) }
        box.record(nil, now: Date())
        XCTAssertTrue(got.isEmpty, "没取到不通知界面")
        box.record([ScopedLimit(label: "Fable", limit: UsageLimit(used: 100, limit: 100))], now: Date())
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got.first?.first?.label, "Fable")
    }
}
