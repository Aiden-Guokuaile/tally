import XCTest
@testable import Tally

/// GLM 专用的假 URLProtocol：类名和静态状态不和别的测试共用，免得互相串请求记录。
final class GLMStubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// GLM Coding Plan 配额：未公开接口的响应形状、信封里的错误、key 从哪儿找和发往哪个区。
final class GLMUsageProviderTests: XCTestCase {

    private var dir: URL!
    private let sample = #"{"code":200,"success":true,"msg":"操作成功","data":{"level":"pro","limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":402,"remaining":1597,"percentage":20,"nextResetTime":1788351145586},{"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":900,"percentage":9,"nextResetTime":1788900000000},{"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":30,"percentage":3}]}}"#
    private let authMessage = "GLM key 无效，或填错了区（国内 / 国际）"
    private let throttledMessage = "GLM 用量接口限流，稍后自动再试"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-glm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        GLMStubProtocol.status = 200
        GLMStubProtocol.body = Data(sample.utf8)
        GLMStubProtocol.headers = [:]
        GLMStubProtocol.requests = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var missing: URL { dir.appendingPathComponent("missing.json") }

    private func file(_ name: String, _ json: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    private func manual(_ key: String = "", region: String = "cn") -> ProviderCredentials {
        var credentials = ProviderCredentials()
        credentials.glmKey = key
        credentials.glmRegion = region
        return credentials
    }

    private func resolve(_ manual: ProviderCredentials, claude: URL? = nil, zcode: URL? = nil, opencode: URL? = nil) -> CredentialDiscovery.Found? {
        GLMUsageProvider.resolveCredential(manual, claudeSettings: claude ?? missing, zcodeConfig: zcode ?? missing, opencodeAuth: opencode ?? missing)
    }

    /// 本机的真文件一个都不读：三个查找位置全指到临时目录。
    private func provider(_ credentials: ProviderCredentials, backoff: QuotaBackoff = QuotaBackoff(), claude: URL? = nil) -> GLMUsageProvider {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GLMStubProtocol.self]
        return GLMUsageProvider(session: URLSession(configuration: config), backoff: backoff, credentials: { credentials },
                                claudeSettings: claude ?? missing, zcodeConfig: missing, opencodeAuth: missing)
    }

    private func thrownMessage<T>(_ work: () async throws -> T) async -> String? {
        do {
            _ = try await work()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: 解析

    func testSampleParsesWindowsByUnitAndNumber() throws {
        let now = Date(timeIntervalSince1970: 1_788_340_000)
        let snapshot = try GLMUsageProvider.snapshot(from: Data(sample.utf8), now: now)
        XCTAssertEqual(snapshot.sessionLimit?.used, 402, "有计数就用 currentValue / usage，不用整数 percentage")
        XCTAssertEqual(snapshot.sessionLimit?.limit, 2000)
        XCTAssertEqual(snapshot.sessionLimit?.resetsAt?.timeIntervalSince1970 ?? 0, 1_788_351_145.586, accuracy: 0.001, "nextResetTime 是毫秒")
        XCTAssertEqual(snapshot.weekLimit?.used, 900)
        XCTAssertEqual(snapshot.weekLimit?.limit, 10000)
        XCTAssertEqual(snapshot.weekLimit?.fraction ?? 0, 0.09, accuracy: 0.0001)
        XCTAssertEqual(snapshot.weekLimit?.resetsAt?.timeIntervalSince1970 ?? 0, 1_788_900_000, accuracy: 0.001)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.lastUpdated, now)
    }

    func testPercentageOnlyAndTimeLimitIgnoredWhateverTheOrder() throws {
        let json = #"""
        {"code":200,"success":true,"data":{"level":"max","limits":[
          {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":999,"percentage":99},
          {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":8},
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":0,"currentValue":0,"percentage":12,"nextResetTime":1788351145586}]}}
        """#
        let snapshot = try GLMUsageProvider.snapshot(from: Data(json.utf8), now: Date())
        XCTAssertEqual(snapshot.sessionLimit?.used, 12, "usage 为 0 时退回 percentage")
        XCTAssertEqual(snapshot.sessionLimit?.limit, 100)
        XCTAssertNotNil(snapshot.sessionLimit?.resetsAt)
        XCTAssertEqual(snapshot.weekLimit?.used, 8, "没有计数只剩 percentage 也能画")
        XCTAssertEqual(snapshot.weekLimit?.limit, 100)
        XCTAssertNil(snapshot.weekLimit?.resetsAt)
        XCTAssertEqual(snapshot.plan, "Max")
    }

    func testOnlyTimeLimitOrUnreadableBodyThrows() {
        let mcpOnly = #"{"code":200,"success":true,"data":{"level":"lite","limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":3}]}}"#
        XCTAssertThrowsError(try GLMUsageProvider.snapshot(from: Data(mcpOnly.utf8), now: Date())) { error in
            XCTAssertEqual(error.localizedDescription, "GLM 用量接口没返回 5 小时 / 周配额", "MCP 额度不能冒充 5 小时配额")
        }
        XCTAssertThrowsError(try GLMUsageProvider.snapshot(from: Data("<html>502</html>".utf8), now: Date())) { error in
            XCTAssertEqual(error.localizedDescription, "GLM 用量接口的响应看不懂")
        }
    }

    func testErrorEnvelopesUnderHTTP200BecomeChineseMessages() {
        let cases: [(body: String, expected: String)] = [
            (#"{"code":401,"msg":"token expired or incorrect","success":false}"#, authMessage),
            (#"{"code":401,"msg":"令牌已过期或验证不正确","success":false}"#, authMessage),
            (#"{"code":1000,"msg":"身份验证失败。","success":false}"#, authMessage),
            (#"{"code":1001,"msg":"Header中未收到Authorization参数，无法进行身份验证。","success":false}"#, authMessage),
            (#"{"code":500,"msg":"当前用户不存在coding plan","success":false,"data":null}"#, "这个账号没有 GLM Coding Plan"),
            (#"{"code":500,"msg":"内部错误","success":false}"#, "GLM 用量接口报错：500 内部错误"),
        ]
        for item in cases {
            XCTAssertThrowsError(try GLMUsageProvider.snapshot(from: Data(item.body.utf8), now: Date()), item.body) { error in
                XCTAssertEqual(error.localizedDescription, item.expected, item.body)
            }
        }
    }

    // MARK: 凭据顺序与区

    func testManualKeyWinsAndRegionPicksHost() throws {
        let claude = try file("settings.json", #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic","ANTHROPIC_AUTH_TOKEN":"from-claude"}}"#)
        let intl = resolve(manual("  manual-key\n", region: "intl"), claude: claude)
        XCTAssertEqual(intl?.token, "manual-key", "首尾空白要去掉，带换行的值进不了请求头")
        XCTAssertEqual(intl?.host, "api.z.ai")
        XCTAssertEqual(resolve(manual("manual-key"), claude: claude)?.host, "open.bigmodel.cn", "没选区默认国内")
        XCTAssertEqual(resolve(manual("   "), claude: claude)?.token, "from-claude", "只填了空白算没填")
    }

    func testClaudeSettingsHostDecidesRegionAndLookalikeIsRejected() throws {
        let cn = try file("cn.json", #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic","ANTHROPIC_AUTH_TOKEN":"cn-key"}}"#)
        XCTAssertEqual(resolve(manual(), claude: cn)?.host, "open.bigmodel.cn")
        let intl = try file("intl.json", #"{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic","ANTHROPIC_AUTH_TOKEN":"intl-key"}}"#)
        XCTAssertEqual(resolve(manual(), claude: intl)?.host, "api.z.ai")
        XCTAssertEqual(resolve(manual(), claude: intl)?.token, "intl-key")
        let lookalike = try file("evil.json", #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn.evil.example/api/anthropic","ANTHROPIC_AUTH_TOKEN":"sk-x"}}"#)
        XCTAssertNil(resolve(manual(), claude: lookalike), "主机名不精确相等就不认，用户的 key 不能发给别人")
    }

    func testZCodeSkipsDisabledAndReadsRegionFromBaseURL() throws {
        let disabledOnly = try file("z1.json", #"""
        {"provider":{
          "builtin:zai-coding-plan":{"enabled":false,"options":{"apiKey":"off-key","baseURL":"https://api.z.ai/api/anthropic"}},
          "builtin:zai":{"enabled":true,"options":{"apiKey":"payg-key","baseURL":"https://api.z.ai/api/anthropic"}}}}
        """#)
        XCTAssertNil(resolve(manual(), zcode: disabledOnly), "关掉的套餐跳过，不是 coding-plan 的条目不认")

        // 关掉的那条排序在前，得跳过它读后面的；没写 enabled 算开着
        let mixed = try file("z2.json", #"""
        {"provider":{
          "builtin:bigmodel-coding-plan":{"enabled":false,"options":{"apiKey":"off-key","baseURL":"https://open.bigmodel.cn/api/anthropic"}},
          "builtin:zai-coding-plan":{"options":{"apiKey":"zai-key","baseURL":"https://api.z.ai/api/anthropic"}}}}
        """#)
        let found = resolve(manual(), zcode: mixed)
        XCTAssertEqual(found?.token, "zai-key")
        XCTAssertEqual(found?.host, "api.z.ai")
        XCTAssertEqual(found?.source, "ZCode 配置")

        let cn = try file("z3.json", #"{"provider":{"builtin:zai-coding-plan":{"enabled":true,"options":{"apiKey":"cn-key","baseURL":"https://open.bigmodel.cn/api/anthropic"}}}}"#)
        XCTAssertEqual(resolve(manual(), zcode: cn)?.host, "open.bigmodel.cn", "区看 baseURL 的主机名，不看 id")

        let noBase = try file("z4.json", #"{"provider":{"builtin:bigmodel-coding-plan":{"enabled":true,"options":{"apiKey":"cn-key"}}}}"#)
        XCTAssertEqual(resolve(manual(), zcode: noBase)?.host, "open.bigmodel.cn", "没有 baseURL 时 id 里的 bigmodel 说明是国内")
    }

    func testOpenCodeProviderIDsAndRegion() throws {
        let both = try file("o1.json", #"{"zai":{"type":"api","key":"payg-key"},"zhipuai-coding-plan":{"type":"api","key":"cn-plan"}}"#)
        let plan = resolve(manual(), opencode: both)
        XCTAssertEqual(plan?.token, "cn-plan", "Coding Plan 的 id 排在按量付费前面")
        XCTAssertEqual(plan?.host, "open.bigmodel.cn")
        XCTAssertEqual(plan?.source, "OpenCode 凭据")

        let zai = try file("o2.json", #"{"zai-coding-plan":{"type":"api","key":"intl-plan"}}"#)
        XCTAssertEqual(resolve(manual(), opencode: zai)?.host, "api.z.ai")

        let bare = try file("o3.json", #"{"zhipuai":"bare-key"}"#)
        XCTAssertEqual(resolve(manual(), opencode: bare)?.token, "bare-key", "直接存字符串的旧形状也认")
        XCTAssertEqual(resolve(manual(), opencode: bare)?.host, "open.bigmodel.cn")

        let unrelated = try file("o4.json", #"{"anthropic":{"type":"api","key":"sk-ant"},"zai":{"type":"oauth","access":"a","refresh":"r","expires":1}}"#)
        XCTAssertNil(resolve(manual(), opencode: unrelated), "别家的 key 不拿，OAuth 条目没有 key")
    }

    func testSourceOrderClaudeThenZCodeThenOpenCode() throws {
        let claude = try file("settings.json", #"{"env":{"ANTHROPIC_BASE_URL":"https://api.z.ai/api/anthropic","ANTHROPIC_AUTH_TOKEN":"from-claude"}}"#)
        let zcode = try file("zcode.json", #"{"provider":{"builtin:zai-coding-plan":{"options":{"apiKey":"from-zcode","baseURL":"https://api.z.ai/api/anthropic"}}}}"#)
        let opencode = try file("auth.json", #"{"zai-coding-plan":{"type":"api","key":"from-opencode"}}"#)
        XCTAssertEqual(resolve(manual(), claude: claude, zcode: zcode, opencode: opencode)?.token, "from-claude")
        XCTAssertEqual(resolve(manual(), zcode: zcode, opencode: opencode)?.token, "from-zcode")
        XCTAssertEqual(resolve(manual(), opencode: opencode)?.token, "from-opencode")
        XCTAssertNil(resolve(manual()))
    }

    // MARK: 请求

    func testRequestSendsRawKeyToTheKeysRegion() async throws {
        let snapshot = try await provider(manual("zai-raw-key", region: "intl")).fetchSnapshot(now: Date())
        XCTAssertEqual(snapshot.sessionLimit?.used, 402)
        XCTAssertEqual(GLMStubProtocol.requests.count, 1)
        let request = try XCTUnwrap(GLMStubProtocol.requests.first)
        XCTAssertEqual(request.url?.host, "api.z.ai")
        XCTAssertEqual(request.url?.path, "/api/monitor/usage/quota/limit")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "zai-raw-key", "原样的 key，不加 Bearer")

        _ = try await provider(manual("cn-raw-key")).fetchSnapshot(now: Date())
        XCTAssertEqual(GLMStubProtocol.requests.last?.url?.host, "open.bigmodel.cn")

        let claude = try file("settings.json", #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic","ANTHROPIC_AUTH_TOKEN":"claude-cn"}}"#)
        _ = try await provider(manual(), claude: claude).fetchSnapshot(now: Date())
        XCTAssertEqual(GLMStubProtocol.requests.last?.url?.host, "open.bigmodel.cn", "Claude Code 里配的是国内区，就只发国内区")
        XCTAssertEqual(GLMStubProtocol.requests.last?.value(forHTTPHeaderField: "Authorization"), "claude-cn")
    }

    func testNoKeyThrowsWithoutRequest() async {
        let message = await thrownMessage { try await provider(manual()).fetchSnapshot(now: Date()) }
        XCTAssertEqual(message, "没有 GLM 的 key：在设置「用量」里填一个，或在 Claude Code 里配好 GLM")
        XCTAssertEqual(GLMStubProtocol.requests.count, 0)
    }

    func testHTTPUnauthorizedIsAuthMessage() async {
        GLMStubProtocol.status = 401
        let message = await thrownMessage { try await provider(manual("bad")).fetchSnapshot(now: Date()) }
        XCTAssertEqual(message, authMessage)
    }

    func testTooManyRequestsBacksOffAndNextFetchSendsNothing() async throws {
        GLMStubProtocol.status = 429
        GLMStubProtocol.headers = ["Retry-After": "120"]
        let backoff = QuotaBackoff()
        let glm = provider(manual("k"), backoff: backoff)
        let now = Date(timeIntervalSince1970: 2_000_000)

        let first = await thrownMessage { try await glm.fetchSnapshot(now: now) }
        XCTAssertEqual(first, throttledMessage)
        XCTAssertEqual(GLMStubProtocol.requests.count, 1)

        GLMStubProtocol.status = 200
        let second = await thrownMessage { try await glm.fetchSnapshot(now: now.addingTimeInterval(60)) }
        XCTAssertEqual(second, throttledMessage)
        XCTAssertEqual(GLMStubProtocol.requests.count, 1, "退避期间不打接口")

        // Retry-After 给了 120 秒，过了之后照常请求，成功就清掉退避
        let snapshot = try await glm.fetchSnapshot(now: now.addingTimeInterval(121))
        XCTAssertNotNil(snapshot.weekLimit)
        XCTAssertEqual(GLMStubProtocol.requests.count, 2)
        XCTAssertTrue(backoff.allows(GLMUsageProvider.backoffKey, now: now))
    }

    // MARK: 设置页文案

    func testDescribeCredentials() throws {
        XCTAssertEqual(GLMUsageProvider.describeCredentials(manual("k", region: "intl"), claudeSettings: missing, zcodeConfig: missing, opencodeAuth: missing),
                       "用手填的 key（国际区 api.z.ai）")
        let claude = try file("settings.json", #"{"env":{"ANTHROPIC_BASE_URL":"https://open.bigmodel.cn/api/anthropic","ANTHROPIC_AUTH_TOKEN":"cn"}}"#)
        XCTAssertEqual(GLMUsageProvider.describeCredentials(manual(), claudeSettings: claude, zcodeConfig: missing, opencodeAuth: missing),
                       "用 Claude Code 设置里的 key（国内区 open.bigmodel.cn）")
        let opencode = try file("auth.json", #"{"zai":{"type":"api","key":"k"}}"#)
        XCTAssertEqual(GLMUsageProvider.describeCredentials(manual(), claudeSettings: missing, zcodeConfig: missing, opencodeAuth: opencode),
                       "用 OpenCode 凭据里的 key（国际区 api.z.ai）")
        XCTAssertEqual(GLMUsageProvider.describeCredentials(manual(), claudeSettings: missing, zcodeConfig: missing, opencodeAuth: missing),
                       "还没有 key：在下面填一个并选对区，或在 Claude Code、ZCode、OpenCode 里配好 GLM Coding Plan")
    }
}
