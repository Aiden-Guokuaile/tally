import XCTest
@testable import Tally

/// 假的 New API 站点：按路径后缀分别回 /api/status 与 /api/user/self，记下收到的请求。
/// 两个接口是并发请求的，记录要加锁；单独一个类名，不和别的测试共用静态状态。
private final class NewAPIStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var body: String
    }

    static let lock = NSLock()
    nonisolated(unsafe) static var replies: [String: Reply] = [:]
    nonisolated(unsafe) static var recorded: [URLRequest] = []

    static func reset() {
        lock.withLock {
            replies = [:]
            recorded = []
        }
    }

    static func reply(to suffix: String, status: Int, body: String) {
        lock.withLock { replies[suffix] = Reply(status: status, body: body) }
    }

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func sent(to suffix: String) -> [URLRequest] {
        requests.filter { $0.url?.path.hasSuffix(suffix) == true }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let reply: Reply = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.replies.first { path.hasSuffix($0.key) }?.value ?? Reply(status: 404, body: "")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private typealias Pricing = NewAPIUsageProvider.Pricing

final class NewAPIUsageProviderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let statusUSD = #"{"success":true,"message":"","data":{"quota_per_unit":500000,"quota_display_type":"USD","usd_exchange_rate":7.25,"display_in_currency":true}}"#
    private let userSelf = #"{"success":true,"message":"","data":{"id":7,"username":"aiden","quota":1500000,"used_quota":500000,"request_count":42}}"#

    override func setUpWithError() throws {
        NewAPIStubProtocol.reset()
        NewAPIStubProtocol.reply(to: "/api/status", status: 200, body: statusUSD)
        NewAPIStubProtocol.reply(to: "/api/user/self", status: 200, body: userSelf)
    }

    private func credentials(base: String = "https://relay.example/v1/", token: String = "tok-abc", user: String = "7") -> ProviderCredentials {
        var credentials = ProviderCredentials()
        credentials.newapiBaseURL = base
        credentials.newapiToken = token
        credentials.newapiUserId = user
        return credentials
    }

    private func provider(_ credentials: ProviderCredentials, backoff: QuotaBackoff = QuotaBackoff()) -> NewAPIUsageProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NewAPIStubProtocol.self]
        return NewAPIUsageProvider(session: URLSession(configuration: config), backoff: backoff, credentials: { credentials })
    }

    /// 抛出的错误在用量行里显示的那句话；没抛返回 nil。
    private func failure(_ provider: NewAPIUsageProvider, at time: Date? = nil) async -> String? {
        do {
            _ = try await provider.fetchSnapshot(now: time ?? now)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // 站点地址

    func testNormalizedBaseURL() {
        XCTAssertEqual(NewAPIUsageProvider.normalizedBaseURL("  https://relay.example/ \n")?.absoluteString, "https://relay.example", "首尾空白和末尾斜杠去掉")
        XCTAssertEqual(NewAPIUsageProvider.normalizedBaseURL("https://relay.example/v1")?.absoluteString, "https://relay.example", "贴进来的 OpenAI 兼容地址去掉 /v1")
        XCTAssertEqual(NewAPIUsageProvider.normalizedBaseURL("https://relay.example/v1/")?.absoluteString, "https://relay.example")
        XCTAssertEqual(NewAPIUsageProvider.normalizedBaseURL("http://10.0.0.2:3000/newapi/V1")?.absoluteString, "http://10.0.0.2:3000/newapi", "子路径和端口保留")
        XCTAssertEqual(NewAPIUsageProvider.normalizedBaseURL("https://relay.example/")?.appendingPathComponent("api/user/self").absoluteString,
                       "https://relay.example/api/user/self")
        XCTAssertNil(NewAPIUsageProvider.normalizedBaseURL("relay.example"), "没写 scheme 不猜")
        XCTAssertNil(NewAPIUsageProvider.normalizedBaseURL("ftp://relay.example"))
        XCTAssertNil(NewAPIUsageProvider.normalizedBaseURL("https://"))
        XCTAssertNil(NewAPIUsageProvider.normalizedBaseURL("   "))
    }

    // 计价设置

    func testPricingReadsSiteSettings() {
        let cny = #"{"success":true,"data":{"quota_per_unit":1000000,"quota_display_type":"CNY","usd_exchange_rate":7.25}}"#
        XCTAssertEqual(NewAPIUsageProvider.pricing(fromStatus: Data(cny.utf8)),
                       Pricing(quotaPerUnit: 1_000_000, displayType: "CNY", usdExchangeRate: 7.25, fromSite: true))

        let tokens = #"{"success":true,"data":{"quota_per_unit":500000,"quota_display_type":"TOKENS"}}"#
        XCTAssertEqual(NewAPIUsageProvider.pricing(fromStatus: Data(tokens.utf8)).displayType, "TOKENS")

        let oldOneAPI = #"{"success":true,"data":{"quota_per_unit":500000,"display_in_currency":false}}"#
        XCTAssertEqual(NewAPIUsageProvider.pricing(fromStatus: Data(oldOneAPI.utf8)).displayType, "TOKENS", "老版 one-api 只有 display_in_currency，关掉就是按 token 显示")

        let custom = #"{"success":true,"data":{"quota_per_unit":500000,"quota_display_type":"CUSTOM","custom_currency_symbol":"€"}}"#
        XCTAssertEqual(NewAPIUsageProvider.pricing(fromStatus: Data(custom.utf8)).displayType, "USD", "自定义货币按底层的美元显示")
    }

    func testPricingFallsBackToDefaults() {
        XCTAssertEqual(Pricing(), Pricing(quotaPerUnit: 500_000, displayType: "USD", usdExchangeRate: nil, fromSite: false))
        XCTAssertEqual(NewAPIUsageProvider.pricing(fromStatus: nil), Pricing(), "请求失败")
        XCTAssertEqual(NewAPIUsageProvider.pricing(fromStatus: Data("<html>login</html>".utf8)), Pricing(), "不是 JSON")
        XCTAssertEqual(NewAPIUsageProvider.pricing(fromStatus: Data(#"{"success":true,"data":{}}"#.utf8)), Pricing(), "字段全缺")
        XCTAssertEqual(NewAPIUsageProvider.pricing(fromStatus: Data(#"{"success":true,"data":{"quota_per_unit":0}}"#.utf8)), Pricing(), "0 不能拿来当除数")
    }

    // 折算

    func testBalancesFollowDisplayType() {
        XCTAssertEqual(NewAPIUsageProvider.balances(remaining: 1_500_000, used: 500_000, pricing: Pricing(fromSite: true)),
                       [Balance(amount: 3, currency: "USD"), Balance(amount: 1, currency: "USD", label: "已用")])

        XCTAssertEqual(NewAPIUsageProvider.balances(remaining: 1_500_000, used: 500_000, pricing: Pricing(displayType: "CNY", usdExchangeRate: 7.25, fromSite: true)),
                       [Balance(amount: 21.75, currency: "CNY"), Balance(amount: 7.25, currency: "CNY", label: "已用")])

        XCTAssertEqual(NewAPIUsageProvider.balances(remaining: 1_500_000, used: 500_000, pricing: Pricing(displayType: "TOKENS", fromSite: true)),
                       [Balance(amount: 1_500_000, currency: "tokens"), Balance(amount: 500_000, currency: "tokens", label: "已用")], "按 token 显示时是原始额度")

        XCTAssertEqual(NewAPIUsageProvider.balances(remaining: 1_500_000, used: 500_000, pricing: Pricing(displayType: "CNY")),
                       [Balance(amount: 3, currency: "USD"), Balance(amount: 1, currency: "USD", label: "已用")], "没给汇率不猜，按美元显示")
    }

    // 请求

    func testSendsTokenAndUserHeaderAndReturnsBalances() async throws {
        let snapshot = try await provider(credentials(token: " tok-abc \n", user: " 7 ")).fetchSnapshot(now: now)
        XCTAssertEqual(snapshot.balances, [Balance(amount: 3, currency: "USD"), Balance(amount: 1, currency: "USD", label: "已用")])
        XCTAssertNil(snapshot.limitsNote)
        XCTAssertNil(snapshot.sessionLimit)
        XCTAssertNil(snapshot.weekLimit)
        XCTAssertEqual(snapshot.lastUpdated, now)

        let user = try XCTUnwrap(NewAPIStubProtocol.sent(to: "/api/user/self").first)
        XCTAssertEqual(user.url?.absoluteString, "https://relay.example/api/user/self", "去掉 /v1 之后再拼")
        XCTAssertEqual(user.httpMethod, "GET")
        XCTAssertEqual(user.value(forHTTPHeaderField: "Authorization"), "Bearer tok-abc")
        XCTAssertEqual(user.value(forHTTPHeaderField: "New-Api-User"), "7", "老站没有这个头直接拒")
        XCTAssertEqual(user.value(forHTTPHeaderField: "Accept"), "application/json")

        let status = try XCTUnwrap(NewAPIStubProtocol.sent(to: "/api/status").first)
        XCTAssertEqual(status.url?.absoluteString, "https://relay.example/api/status")
        XCTAssertNil(status.value(forHTTPHeaderField: "Authorization"), "公开接口不带令牌")
        XCTAssertEqual(NewAPIStubProtocol.requests.count, 2)
    }

    func testSiteInYuanShowsYuan() async throws {
        NewAPIStubProtocol.reply(to: "/api/status", status: 200,
                                 body: #"{"success":true,"data":{"quota_per_unit":500000,"quota_display_type":"CNY","usd_exchange_rate":7.25}}"#)
        let snapshot = try await provider(credentials()).fetchSnapshot(now: now)
        XCTAssertEqual(snapshot.balances, [Balance(amount: 21.75, currency: "CNY"), Balance(amount: 7.25, currency: "CNY", label: "已用")])
        XCTAssertNil(snapshot.limitsNote)
    }

    func testStatusFailureStillShowsBalancesWithNote() async throws {
        NewAPIStubProtocol.reply(to: "/api/status", status: 502, body: "<html>Bad Gateway</html>")
        let snapshot = try await provider(credentials()).fetchSnapshot(now: now)
        XCTAssertEqual(snapshot.balances, [Balance(amount: 3, currency: "USD"), Balance(amount: 1, currency: "USD", label: "已用")], "计价设置取不到不让整行失败")
        XCTAssertEqual(snapshot.limitsNote, "站点没返回计价设置，按 $1 = 500000 额度算")
    }

    func testRejectionCarriesSiteMessage() async {
        NewAPIStubProtocol.reply(to: "/api/user/self", status: 200, body: #"{"success":false,"message":"用户已被封禁"}"#)
        let banned = await failure(provider(credentials()))
        XCTAssertEqual(banned, "New API 访问令牌或用户 ID 不对：用户已被封禁")

        NewAPIStubProtocol.reply(to: "/api/user/self", status: 401, body: #"{"success":false,"message":"无权进行此操作，New-Api-User 与登录用户不匹配"}"#)
        let mismatch = await failure(provider(credentials()))
        XCTAssertEqual(mismatch, "New API 访问令牌或用户 ID 不对：无权进行此操作，New-Api-User 与登录用户不匹配")

        NewAPIStubProtocol.reply(to: "/api/user/self", status: 403, body: "")
        let bare = await failure(provider(credentials()))
        XCTAssertEqual(bare, "New API 访问令牌或用户 ID 不对：HTTP 403", "没给原因就报状态码")
    }

    func testHTMLPageIsNotNewAPI() async {
        NewAPIStubProtocol.reply(to: "/api/user/self", status: 200, body: "<!doctype html><html><body>登录</body></html>")
        let message = await failure(provider(credentials()))
        XCTAssertEqual(message, "relay.example 返回的不是 New API 的数据，站点地址填对了吗")
    }

    func testServerErrorNamesTheStatus() async {
        NewAPIStubProtocol.reply(to: "/api/user/self", status: 500, body: "<html>oops</html>")
        let message = await failure(provider(credentials()))
        XCTAssertEqual(message, "New API 余额查询失败（HTTP 500）", "5xx 不是地址填错，不说「不是 New API」")
    }

    func testTooManyRequestsBacksOffWithoutSendingAgain() async {
        let backoff = QuotaBackoff()
        let relay = provider(credentials(), backoff: backoff)
        NewAPIStubProtocol.reply(to: "/api/user/self", status: 429, body: "")
        let first = await failure(relay)
        XCTAssertEqual(first?.contains("限流"), true)
        XCTAssertFalse(backoff.allows(NewAPIUsageProvider.backoffKey, now: now))

        NewAPIStubProtocol.reply(to: "/api/user/self", status: 200, body: userSelf)
        let second = await failure(relay)
        XCTAssertEqual(second?.contains("限流"), true)
        // 只数余额接口：/api/status 是并发发出的，第一轮抛错时它可能收到也可能被取消
        XCTAssertEqual(NewAPIStubProtocol.sent(to: "/api/user/self").count, 1, "退避期间不打接口")

        let later = now.addingTimeInterval(QuotaBackoff.base + 1)
        let third = await failure(relay, at: later)
        XCTAssertNil(third, "冷却过了照常请求")
        XCTAssertEqual(NewAPIStubProtocol.sent(to: "/api/user/self").count, 2)
        XCTAssertTrue(backoff.allows(NewAPIUsageProvider.backoffKey, now: later), "成功一次清零")
    }

    func testBackoffIsCheckedBeforeAnyRequest() async {
        let backoff = QuotaBackoff()
        backoff.throttled(NewAPIUsageProvider.backoffKey, now: now, retryAfter: nil)
        let message = await failure(provider(credentials(base: "https://quiet.example"), backoff: backoff))
        XCTAssertEqual(message, "New API 限流中，过会儿自动再查")
        XCTAssertFalse(NewAPIStubProtocol.requests.contains { $0.url?.absoluteString.hasPrefix("https://quiet.example") == true }, "计价设置也不取")
    }

    func testMissingFieldsAreNotConfiguredAndSendNothing() async {
        let unset = "https://unset.example"
        for missing in [credentials(base: " "), credentials(base: unset, token: ""), credentials(base: unset, user: "\n")] {
            do {
                _ = try await provider(missing).fetchSnapshot(now: now)
                XCTFail("没填完应该抛错")
            } catch UsageError.notConfigured(let message) {
                XCTAssertEqual(message, "New API 还没填完：站点地址、访问令牌、用户 ID 都要")
            } catch {
                XCTFail("应该是 notConfigured，实际是 \(error)")
            }
        }
        XCTAssertFalse(NewAPIStubProtocol.requests.contains { $0.url?.absoluteString.hasPrefix(unset) == true })

        do {
            _ = try await provider(credentials(base: "relay.example")).fetchSnapshot(now: now)
            XCTFail("地址不对应该抛错")
        } catch UsageError.notConfigured(let message) {
            XCTAssertTrue(message.contains("站点地址不对"), message)
        } catch {
            XCTFail("应该是 notConfigured，实际是 \(error)")
        }
    }

    // 设置页说明

    func testDescribeCredentials() {
        XCTAssertEqual(NewAPIUsageProvider.describeCredentials(credentials(user: " 7 ")), "站点 relay.example · 用户 7")
        XCTAssertEqual(NewAPIUsageProvider.describeCredentials(ProviderCredentials()), "还没填：站点地址、访问令牌、用户 ID")
        XCTAssertEqual(NewAPIUsageProvider.describeCredentials(credentials(token: "  ")), "还没填：访问令牌")
        XCTAssertTrue(NewAPIUsageProvider.describeCredentials(credentials(base: "relay.example")).contains("站点地址不对"))
    }
}
