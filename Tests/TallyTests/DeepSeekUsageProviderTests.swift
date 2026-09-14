import XCTest
@testable import Tally

/// 假的 DeepSeek 接口：记下收到的请求，按预设状态码与响应体回。单独一个类名，不和别的测试共用静态状态。
private final class DeepSeekStubProtocol: URLProtocol {
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

final class DeepSeekUsageProviderTests: XCTestCase {

    private var dir: URL!
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let sample = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.00","granted_balance":"10.00","topped_up_balance":"100.00"},{"currency":"USD","total_balance":"3.50","granted_balance":"0.00","topped_up_balance":"3.50"}]}"#

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-deepseek-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DeepSeekStubProtocol.status = 200
        DeepSeekStubProtocol.body = Data(sample.utf8)
        DeepSeekStubProtocol.requests = []
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: dir)
    }

    /// 一律显式传 settings.json：默认值指向本机真的 Claude Code 设置，还会去问登录 shell。
    private var noSettings: URL { dir.appendingPathComponent("missing-settings.json") }

    private func claudeSettings(baseURL: String, token: String) throws -> URL {
        let file = dir.appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["env": ["ANTHROPIC_BASE_URL": baseURL, "ANTHROPIC_AUTH_TOKEN": token]]).write(to: file)
        return file
    }

    private func manual(_ key: String) -> ProviderCredentials {
        var credentials = ProviderCredentials()
        credentials.deepseekKey = key
        return credentials
    }

    private func provider(_ credentials: ProviderCredentials, settings: URL? = nil, backoff: QuotaBackoff = QuotaBackoff()) -> DeepSeekUsageProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeepSeekStubProtocol.self]
        return DeepSeekUsageProvider(session: URLSession(configuration: config), backoff: backoff,
                                     credentials: { credentials }, claudeSettings: settings ?? noSettings)
    }

    /// 抛出的错误在用量行里显示的那句话；没抛返回 nil。
    private func failure(_ provider: DeepSeekUsageProvider, at time: Date? = nil) async -> String? {
        do {
            _ = try await provider.fetchSnapshot(now: time ?? now)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // 解析

    func testTwoCurrenciesAreTwoBalances() throws {
        let snapshot = try XCTUnwrap(DeepSeekUsageProvider.parse(Data(sample.utf8), now: now))
        XCTAssertEqual(snapshot.balances, [Balance(amount: 110, currency: "CNY"), Balance(amount: 3.5, currency: "USD")], "两个币种各一笔，不加在一起")
        XCTAssertNil(snapshot.limitsNote)
        XCTAssertNil(snapshot.sessionLimit)
        XCTAssertNil(snapshot.weekLimit)
        XCTAssertEqual(snapshot.lastUpdated, now)
    }

    func testUnparseableAmountIsSkippedNotZero() throws {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"--"},{"currency":"USD","total_balance":"1.25"}]}"#
        let snapshot = try XCTUnwrap(DeepSeekUsageProvider.parse(Data(json.utf8), now: now))
        XCTAssertEqual(snapshot.balances, [Balance(amount: 1.25, currency: "USD")], "读不出的金额当没有，不当 0")
    }

    /// 一笔余额都读不出时当认不出：成功返回空余额的话，这一行只剩名字，没有任何报错可看。
    func testNoReadableBalanceIsUnrecognized() throws {
        XCTAssertNil(DeepSeekUsageProvider.parse(Data(#"{"is_available":true,"balance_infos":[]}"#.utf8), now: now))
        XCTAssertNil(DeepSeekUsageProvider.parse(Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"--"}]}"#.utf8), now: now))
        let numeric = try XCTUnwrap(DeepSeekUsageProvider.parse(Data(#"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":12.5}]}"#.utf8), now: now))
        XCTAssertEqual(numeric.balances, [Balance(amount: 12.5, currency: "CNY")], "金额改成数字也认")
    }

    func testUnavailableFlagAloneDecidesTheNote() throws {
        let unavailable = #"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"5.00"}]}"#
        let snapshot = try XCTUnwrap(DeepSeekUsageProvider.parse(Data(unavailable.utf8), now: now))
        XCTAssertEqual(snapshot.limitsNote, "余额不足，调用会被拒")
        XCTAssertEqual(snapshot.balances, [Balance(amount: 5, currency: "CNY")])

        let zeroButAvailable = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"0.00"}]}"#
        let zero = try XCTUnwrap(DeepSeekUsageProvider.parse(Data(zeroButAvailable.utf8), now: now))
        XCTAssertNil(zero.limitsNote, "金额是 0 但接口说能用，只听标志")
    }

    func testUnrecognizedBodyIsNil() {
        XCTAssertNil(DeepSeekUsageProvider.parse(Data("<html></html>".utf8), now: now))
        XCTAssertNil(DeepSeekUsageProvider.parse(Data("{}".utf8), now: now))
    }

    // 用哪个 key

    func testManualKeyWinsOverClaudeSettings() throws {
        let settings = try claudeSettings(baseURL: "https://api.deepseek.com/anthropic", token: "sk-claude")
        let resolved = DeepSeekUsageProvider.resolveKey(manual("  sk-typed \n"), claudeSettings: settings)
        XCTAssertEqual(resolved?.key, "sk-typed", "手填的去掉首尾空白后优先")
        XCTAssertEqual(resolved?.source, .manual)
    }

    func testClaudeSettingsOnlyForExactHost() throws {
        let settings = try claudeSettings(baseURL: "https://api.deepseek.com/anthropic", token: "sk-claude")
        let resolved = DeepSeekUsageProvider.resolveKey(manual("   "), claudeSettings: settings)
        XCTAssertEqual(resolved?.key, "sk-claude", "只有空白的手填当没填")
        XCTAssertEqual(resolved?.source, .claudeSettings)

        let lookalike = try claudeSettings(baseURL: "https://api.deepseek.com.evil.example/anthropic", token: "sk-x")
        XCTAssertNil(DeepSeekUsageProvider.resolveKey(ProviderCredentials(), claudeSettings: lookalike), "长得像的主机名不认，不然 key 会发给别人")
    }

    func testNoKeyIsNotConfiguredAndSendsNothing() async {
        do {
            _ = try await provider(ProviderCredentials()).fetchSnapshot(now: now)
            XCTFail("没有 key 应该抛错")
        } catch UsageError.notConfigured(let message) {
            XCTAssertEqual(message, "没有 DeepSeek 的 key：在设置「用量」里填一个")
        } catch {
            XCTFail("应该是 notConfigured，实际是 \(error)")
        }
        XCTAssertTrue(DeepSeekStubProtocol.requests.isEmpty)
    }

    func testDescribeCredentials() throws {
        let settings = try claudeSettings(baseURL: "https://api.deepseek.com/anthropic", token: "sk-claude")
        XCTAssertEqual(DeepSeekUsageProvider.describeCredentials(manual("sk-typed"), claudeSettings: settings), "用手填的 key")
        XCTAssertEqual(DeepSeekUsageProvider.describeCredentials(ProviderCredentials(), claudeSettings: settings), "用 Claude Code 设置里的 key")
        XCTAssertEqual(DeepSeekUsageProvider.describeCredentials(ProviderCredentials(), claudeSettings: noSettings),
                       "还没有 key：在下面填一个，或在 Claude Code 里把 DeepSeek 配好")
    }

    // 请求

    func testSendsBearerKeyAndReturnsBalances() async throws {
        let snapshot = try await provider(manual("sk-typed")).fetchSnapshot(now: now)
        XCTAssertEqual(snapshot.balances.count, 2)
        XCTAssertEqual(DeepSeekStubProtocol.requests.count, 1)
        let request = try XCTUnwrap(DeepSeekStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-typed")
    }

    func testClaudeSettingsKeyIsSent() async throws {
        let settings = try claudeSettings(baseURL: "https://api.deepseek.com/anthropic", token: "sk-claude")
        _ = try await provider(ProviderCredentials(), settings: settings).fetchSnapshot(now: now)
        XCTAssertEqual(DeepSeekStubProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-claude")
    }

    func testUnauthorizedSaysKeyIsBad() async {
        DeepSeekStubProtocol.status = 401
        let message = await failure(provider(manual("sk-bad")))
        XCTAssertEqual(message, "DeepSeek key 无效或被停用（HTTP 401）")
    }

    func testTooManyRequestsBacksOffWithoutSendingAgain() async {
        let backoff = QuotaBackoff()
        let deepseek = provider(manual("sk-typed"), backoff: backoff)
        DeepSeekStubProtocol.status = 429
        let first = await failure(deepseek)
        XCTAssertEqual(first?.contains("限流"), true)
        XCTAssertEqual(DeepSeekStubProtocol.requests.count, 1)

        DeepSeekStubProtocol.status = 200
        let second = await failure(deepseek)
        XCTAssertEqual(second?.contains("限流"), true)
        XCTAssertEqual(DeepSeekStubProtocol.requests.count, 1, "退避期间不打接口")

        let later = now.addingTimeInterval(QuotaBackoff.base + 1)
        let third = await failure(deepseek, at: later)
        XCTAssertNil(third, "冷却过了照常请求")
        XCTAssertEqual(DeepSeekStubProtocol.requests.count, 2)
        XCTAssertTrue(backoff.allows(DeepSeekUsageProvider.backoffKey, now: later), "成功一次清零")
    }

    func testServerErrorAndUnreadableBodyNameTheStatus() async {
        let deepseek = provider(manual("sk-typed"))
        DeepSeekStubProtocol.status = 500
        let serverError = await failure(deepseek)
        XCTAssertEqual(serverError?.contains("HTTP 500"), true)

        DeepSeekStubProtocol.status = 200
        DeepSeekStubProtocol.body = Data("{}".utf8)
        let unreadable = await failure(deepseek)
        XCTAssertEqual(unreadable?.contains("HTTP 200"), true)
    }
}
