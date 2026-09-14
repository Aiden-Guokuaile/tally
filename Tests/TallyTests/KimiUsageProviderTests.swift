import XCTest
@testable import Tally

/// 假的 URLProtocol：按「主机 + 路径」回预设的状态码与响应体，没配的回 500。
/// 两个接口是并发请求的，记请求要加锁。
final class KimiStubProtocol: URLProtocol {
    struct Route {
        var status: Int
        var body: String
        var headers: [String: String] = [:]
    }

    static let lock = NSLock()
    nonisolated(unsafe) static var routes: [String: Route] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    static func reset() {
        lock.withLock {
            routes = [:]
            requests = []
        }
    }

    static func sent(to host: String) -> [URLRequest] {
        lock.withLock { requests.filter { $0.url?.host == host } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let url = request.url!
        Self.lock.lock()
        Self.requests.append(request)
        let route = Self.routes[(url.host ?? "") + url.path] ?? Route(status: 500, body: "")
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: nil, headerFields: route.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(route.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class KimiUsageProviderTests: XCTestCase {

    typealias Credential = KimiUsageProvider.CodeCredential

    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 1_789_387_200) // 2026-09-14T12:00:00Z

    /// 实测 `GET /coding/v1/usages` 的响应（去掉了用户 ID）。
    private let codeSample = #"{"user":{"membership":{"level":"LEVEL_ADVANCED"}},"usage":{"limit":"100","used":"2","remaining":"98","resetTime":"2026-09-15T19:39:34.389610Z"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"100","used":"8","remaining":"92","resetTime":"2026-09-14T15:00:00.123Z"}}]}"#
    private let balanceSample = #"{"code":0,"data":{"available_balance":49.58894,"voucher_balance":46.58893,"cash_balance":3.00001},"scode":"0x0","status":true}"#

    private let codePath = "api.kimi.com/coding/v1/usages"
    private let cnBalancePath = "api.moonshot.cn/v1/users/me/balance"
    private let intlBalancePath = "api.moonshot.ai/v1/users/me/balance"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-kimi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        KimiStubProtocol.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        KimiStubProtocol.reset()
    }

    private var claudeSettings: URL { dir.appendingPathComponent("settings.json") }
    private var kimiCodeHome: URL { dir.appendingPathComponent("kimi-code") }

    private func writeClaudeSettings(baseURL: String, token: String) throws {
        let object: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": baseURL, "ANTHROPIC_AUTH_TOKEN": token]]
        try JSONSerialization.data(withJSONObject: object).write(to: claudeSettings)
    }

    @discardableResult
    private func writeKimiCodeLogin(token: String, expiresAt: Double) throws -> URL {
        let folder = kimiCodeHome.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("kimi-code.json")
        let object: [String: Any] = ["access_token": token, "refresh_token": "never-read", "expires_at": expiresAt, "expires_in": 900]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return file
    }

    private func provider(_ credentials: ProviderCredentials, backoff: QuotaBackoff = QuotaBackoff()) -> KimiUsageProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [KimiStubProtocol.self]
        return KimiUsageProvider(session: URLSession(configuration: config), backoff: backoff,
                                 credentials: { credentials }, claudeSettings: claudeSettings, kimiCodeHome: kimiCodeHome)
    }

    private func manual(code: String = "", moonshot: String = "", region: String = "cn") -> ProviderCredentials {
        var credentials = ProviderCredentials()
        credentials.kimiCodeKey = code
        credentials.moonshotKey = moonshot
        credentials.moonshotRegion = region
        return credentials
    }

    private func route(_ path: String, _ status: Int, _ body: String = "", headers: [String: String] = [:]) {
        let value = KimiStubProtocol.Route(status: status, body: body, headers: headers)
        KimiStubProtocol.lock.withLock { KimiStubProtocol.routes[path] = value }
    }

    private func seconds(_ window: [String: Any]) -> Double? {
        KimiUsageProvider.windowSeconds(window)
    }

    private func assertThrows(_ provider: KimiUsageProvider, message: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await provider.fetchSnapshot(now: now)
            XCTFail("应该抛错", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, message, file: file, line: line)
        }
    }

    // 解析

    func testParsesSample() throws {
        let usage = try XCTUnwrap(KimiUsageProvider.parseCodeUsage(Data(codeSample.utf8)))
        XCTAssertEqual(usage.session?.used, 8)
        XCTAssertEqual(usage.session?.limit, 100)
        let sessionReset = try XCTUnwrap(usage.session?.resetsAt, "带小数秒的重置时间")
        XCTAssertEqual(sessionReset.timeIntervalSince1970, 1_789_398_000.123, accuracy: 0.001)
        XCTAssertEqual(usage.week?.used, 2, "顶层 usage 是周窗口")
        let weekReset = try XCTUnwrap(usage.week?.resetsAt)
        XCTAssertEqual(weekReset.timeIntervalSince1970, 1_789_501_174.389, accuracy: 0.001)
        XCTAssertEqual(usage.plan, "Advanced")
    }

    func testUsedDerivedFromRemainingAndOtherUnits() throws {
        let json = """
        {"usage":{"limit":"200","remaining":"150","resetTime":"2026-09-20T08:00:00Z"},
         "limits":[{"window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"},"detail":{"limit":"50","remaining":"1"}},
                   {"window":{"duration":5,"timeUnit":"TIME_UNIT_HOUR"},"detail":{"limit":"100","remaining":"70"}}]}
        """
        let usage = try XCTUnwrap(KimiUsageProvider.parseCodeUsage(Data(json.utf8)))
        XCTAssertEqual(usage.week?.used, 50, "没有 used 就是 limit - remaining")
        XCTAssertEqual(usage.week?.resetsAt, Date(timeIntervalSince1970: 1_789_891_200), "不带小数秒的也认")
        XCTAssertEqual(usage.session?.used, 30, "1 天的窗口不是 5 小时，挑后面那条")
        XCTAssertNil(usage.plan)

        XCTAssertEqual(seconds(["duration": 18000, "timeUnit": "TIME_UNIT_SECOND"]), 18000)
        XCTAssertEqual(seconds(["duration": "300", "timeUnit": "TIME_UNIT_MINUTE"]), 18000)
        XCTAssertEqual(seconds(["duration": 2, "timeUnit": "TIME_UNIT_DAY"]), 172_800)
        XCTAssertNil(seconds(["duration": 1, "timeUnit": "TIME_UNIT_WEEK"]), "不认识的单位不猜")
        XCTAssertNil(KimiUsageProvider.parseCodeUsage(Data(#"{"limits":[]}"#.utf8)), "一条窗口都没有不算读数")
    }

    func testPlanName() {
        XCTAssertEqual(KimiUsageProvider.planName("LEVEL_ADVANCED"), "Advanced")
        XCTAssertEqual(KimiUsageProvider.planName("LEVEL_VERY_HIGH"), "Very High")
        XCTAssertNil(KimiUsageProvider.planName(""))
        XCTAssertNil(KimiUsageProvider.planName(nil))
    }

    func testParsesBalance() throws {
        let amount = try XCTUnwrap(KimiUsageProvider.parseBalance(Data(balanceSample.utf8)))
        XCTAssertEqual(amount, 49.58894, accuracy: 1e-9)
        XCTAssertNil(KimiUsageProvider.parseBalance(Data(#"{"code":0,"status":true}"#.utf8)))
    }

    // 凭据

    func testBalanceRegionFromManualSettingOrFoundHost() throws {
        let intl = try XCTUnwrap(KimiUsageProvider.balanceCredential(manual(moonshot: "mk-1", region: "intl"), claudeSettings: claudeSettings))
        XCTAssertEqual(intl.url.absoluteString, "https://api.moonshot.ai/v1/users/me/balance")
        XCTAssertEqual(intl.currency, "USD")
        let cn = try XCTUnwrap(KimiUsageProvider.balanceCredential(manual(moonshot: "mk-1"), claudeSettings: claudeSettings))
        XCTAssertEqual(cn.host, "api.moonshot.cn")
        XCTAssertEqual(cn.currency, "CNY")

        try writeClaudeSettings(baseURL: "https://api.moonshot.ai/anthropic", token: "mk-claude")
        let found = try XCTUnwrap(KimiUsageProvider.balanceCredential(manual(), claudeSettings: claudeSettings))
        XCTAssertEqual(found, KimiUsageProvider.BalanceCredential(key: "mk-claude", host: "api.moonshot.ai", source: .claudeSettings), "找到的主机决定区")
        XCTAssertEqual(found.currency, "USD")
        XCTAssertEqual(KimiUsageProvider.balanceCredential(manual(moonshot: "mk-1"), claudeSettings: claudeSettings)?.key, "mk-1", "手填的优先")
    }

    func testCodeCredentialOrder() throws {
        try writeKimiCodeLogin(token: "oauth-1", expiresAt: now.timeIntervalSince1970 + 600)
        func resolve(_ credentials: ProviderCredentials) -> Credential? {
            KimiUsageProvider.codeCredential(credentials, claudeSettings: claudeSettings, kimiCodeHome: kimiCodeHome, now: now)
        }
        XCTAssertEqual(resolve(manual()), Credential(token: "oauth-1", source: .kimiCodeLogin, expired: false))

        try writeClaudeSettings(baseURL: "https://api.kimi.com.evil.example/coding/", token: "sk-lookalike")
        XCTAssertEqual(resolve(manual())?.token, "oauth-1", "长得像的主机不认，退到 Kimi Code 登录")

        try writeClaudeSettings(baseURL: "https://api.kimi.com/coding/", token: "sk-kimi-claude")
        XCTAssertEqual(resolve(manual()), Credential(token: "sk-kimi-claude", source: .claudeSettings, expired: false))
        XCTAssertEqual(resolve(manual(code: " sk-kimi-manual ")), Credential(token: "sk-kimi-manual", source: .manual, expired: false))

        try FileManager.default.removeItem(at: claudeSettings)
        try writeKimiCodeLogin(token: "oauth-old", expiresAt: now.timeIntervalSince1970 - 1)
        XCTAssertEqual(resolve(manual()), Credential(token: "oauth-old", source: .kimiCodeLogin, expired: true))
        XCTAssertNil(KimiUsageProvider.codeCredential(manual(), claudeSettings: claudeSettings, kimiCodeHome: dir.appendingPathComponent("none"), now: now))
    }

    func testDescribeCredentials() throws {
        func describe(_ credentials: ProviderCredentials) -> String {
            KimiUsageProvider.describeCredentials(credentials, claudeSettings: claudeSettings, kimiCodeHome: kimiCodeHome, now: now)
        }
        XCTAssertEqual(describe(manual()), "没有 Kimi 的 key：在设置「用量」里填，或登录 Kimi Code")
        XCTAssertEqual(describe(manual(code: "sk-kimi-1", moonshot: "mk", region: "intl")),
                       "Kimi Code 配额：用设置里填的 key\n开放平台余额：用设置里填的 key（国际站，美元）")

        try writeClaudeSettings(baseURL: "https://api.moonshot.cn/anthropic", token: "mk-claude")
        XCTAssertEqual(describe(manual()),
                       "Kimi Code 配额：没找到 key，填 sk-kimi- 开头的 key 或登录 Kimi Code\n开放平台余额：用 Claude Code 设置里的 key（国内站，人民币）")

        try writeKimiCodeLogin(token: "oauth-1", expiresAt: now.timeIntervalSince1970 + 600)
        XCTAssertEqual(describe(manual()), "Kimi Code 配额：用 Kimi Code 的登录\n开放平台余额：用 Claude Code 设置里的 key（国内站，人民币）")
        try writeKimiCodeLogin(token: "oauth-1", expiresAt: now.timeIntervalSince1970 - 1)
        XCTAssertEqual(describe(manual()), "Kimi Code 登录过期：去 Kimi Code 跑一下\n开放平台余额：用 Claude Code 设置里的 key（国内站，人民币）")
    }

    // 请求

    func testFetchesBothPartsWithTheirOwnKeys() async throws {
        route(codePath, 200, codeSample)
        route(intlBalancePath, 200, balanceSample)
        let snapshot = try await provider(manual(code: "sk-kimi-1", moonshot: "mk-1", region: "intl")).fetchSnapshot(now: now)

        XCTAssertEqual(snapshot.sessionLimit?.used, 8)
        XCTAssertEqual(snapshot.weekLimit?.used, 2)
        XCTAssertEqual(snapshot.plan, "Advanced")
        XCTAssertEqual(snapshot.balances.count, 1)
        XCTAssertEqual(snapshot.balances.first?.currency, "USD")
        XCTAssertEqual(snapshot.balances.first?.amount ?? 0, 49.58894, accuracy: 1e-9)
        XCTAssertEqual(snapshot.balances.first?.label, "余额")
        XCTAssertNil(snapshot.limitsNote)
        XCTAssertEqual(snapshot.lastUpdated, now)

        let code = KimiStubProtocol.sent(to: "api.kimi.com")
        XCTAssertEqual(code.count, 1)
        XCTAssertEqual(code.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-kimi-1")
        XCTAssertEqual(code.first?.value(forHTTPHeaderField: "User-Agent"), "Tally")
        let balance = KimiStubProtocol.sent(to: "api.moonshot.ai")
        XCTAssertEqual(balance.count, 1)
        XCTAssertEqual(balance.first?.value(forHTTPHeaderField: "Authorization"), "Bearer mk-1")
        XCTAssertTrue(KimiStubProtocol.sent(to: "api.moonshot.cn").isEmpty, "国际站的 key 不发给国内站")
    }

    func testNoPlanIsNotAnError() async throws {
        route(codePath, 404, #"{"message":"not found"}"#)
        route(cnBalancePath, 200, balanceSample)
        let both = try await provider(manual(code: "sk-kimi-1", moonshot: "mk-1")).fetchSnapshot(now: now)
        XCTAssertNil(both.sessionLimit)
        XCTAssertNil(both.weekLimit)
        XCTAssertNil(both.limitsNote, "没会员不是错")
        XCTAssertEqual(both.balances.first?.currency, "CNY")

        let codeOnly = try await provider(manual(code: "sk-kimi-1")).fetchSnapshot(now: now)
        XCTAssertNil(codeOnly.sessionLimit)
        XCTAssertNil(codeOnly.weekLimit)
        XCTAssertEqual(codeOnly.limitsNote, "这个账号没开 Kimi Code 会员")
    }

    func testOnePartFailingBecomesNote() async throws {
        route(codePath, 401)
        route(cnBalancePath, 200, balanceSample)
        let codeFailed = try await provider(manual(code: "sk-kimi-bad", moonshot: "mk-1")).fetchSnapshot(now: now)
        XCTAssertEqual(codeFailed.limitsNote, "Kimi Code 的 key 无效")
        XCTAssertEqual(codeFailed.balances.count, 1)

        route(codePath, 200, codeSample)
        route(cnBalancePath, 500)
        let balanceFailed = try await provider(manual(code: "sk-kimi-1", moonshot: "mk-1")).fetchSnapshot(now: now)
        XCTAssertEqual(balanceFailed.sessionLimit?.used, 8)
        XCTAssertTrue(balanceFailed.balances.isEmpty)
        XCTAssertEqual(balanceFailed.limitsNote, "Kimi 余额 HTTP 500")
    }

    func testExpiredKimiCodeLoginSendsNoRequest() async throws {
        let file = try writeKimiCodeLogin(token: "oauth-old", expiresAt: now.timeIntervalSince1970 - 60)
        let before = try Data(contentsOf: file)
        route(codePath, 200, codeSample)
        route(cnBalancePath, 200, balanceSample)

        let withBalance = try await provider(manual(moonshot: "mk-1")).fetchSnapshot(now: now)
        XCTAssertEqual(withBalance.limitsNote, "Kimi Code 登录过期：去 Kimi Code 跑一下")
        XCTAssertEqual(withBalance.balances.count, 1)
        XCTAssertTrue(KimiStubProtocol.sent(to: "api.kimi.com").isEmpty, "过期的 token 不发")

        await assertThrows(provider(manual()), message: "Kimi Code 登录过期：去 Kimi Code 跑一下")
        XCTAssertTrue(KimiStubProtocol.sent(to: "api.kimi.com").isEmpty)
        let after = try Data(contentsOf: file)
        XCTAssertEqual(after, before, "登录文件一个字节都不能动")
    }

    func testRejectedKimiCodeLoginSaysLoginExpired() async throws {
        try writeKimiCodeLogin(token: "oauth-1", expiresAt: now.timeIntervalSince1970 + 600)
        route(codePath, 401)
        await assertThrows(provider(manual()), message: "Kimi Code 登录过期：去 Kimi Code 跑一下")
        XCTAssertEqual(KimiStubProtocol.sent(to: "api.kimi.com").first?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-1")
    }

    func testBothFailingThrowsTheActionableOne() async throws {
        route(codePath, 500)
        route(cnBalancePath, 401)
        await assertThrows(provider(manual(code: "sk-kimi-1", moonshot: "mk-wrong-region")),
                           message: "Kimi 开放平台的 key 无效（国内站、国际站不通用）")
    }

    func testNothingConfiguredThrowsWithoutRequests() async throws {
        try writeClaudeSettings(baseURL: "https://api.anthropic.com", token: "sk-ant-real")
        await assertThrows(provider(manual()), message: "没有 Kimi 的 key：在设置「用量」里填，或登录 Kimi Code")
        let sent = KimiStubProtocol.lock.withLock { KimiStubProtocol.requests.count }
        XCTAssertEqual(sent, 0, "用户自己的 Anthropic key 不能发出去")
    }

    func testRateLimitBacksOffPerEndpoint() async throws {
        let backoff = QuotaBackoff()
        route(codePath, 429, "", headers: ["Retry-After": "120"])
        route(cnBalancePath, 200, balanceSample)
        let first = try await provider(manual(code: "sk-kimi-1", moonshot: "mk-1"), backoff: backoff).fetchSnapshot(now: now)
        XCTAssertEqual(first.limitsNote, "Kimi Code 配额被限流，稍后再查")
        XCTAssertFalse(backoff.allows(KimiUsageProvider.codeBackoffKey, now: now.addingTimeInterval(119)))
        XCTAssertTrue(backoff.allows(KimiUsageProvider.balanceBackoffKey, now: now), "余额接口不受牵连")

        route(codePath, 200, codeSample)
        let second = try await provider(manual(code: "sk-kimi-1", moonshot: "mk-1"), backoff: backoff).fetchSnapshot(now: now.addingTimeInterval(60))
        XCTAssertEqual(second.limitsNote, "Kimi Code 配额被限流，稍后再查")
        XCTAssertEqual(KimiStubProtocol.sent(to: "api.kimi.com").count, 1, "退避期间不打接口")
        XCTAssertEqual(KimiStubProtocol.sent(to: "api.moonshot.cn").count, 2)
    }
}
