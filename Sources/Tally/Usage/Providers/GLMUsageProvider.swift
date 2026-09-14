import Foundation

/// 智谱 GLM Coding Plan 的 5 小时 / 周配额，读 `/api/monitor/usage/quota/limit`。这个接口没有公开文档（codenotch、Pulse 都在用），
/// 形状随时可能变，由 GLMUsageProviderTests 钉住。
/// 国内（open.bigmodel.cn）和国际（api.z.ai）是两套账号：key 在哪个区找到就只发哪个区，发错区只会回一句「身份验证失败」，
/// 看着像 key 坏了，而且等于把 key 交给了用户没用的那个站。
struct GLMUsageProvider: UsageProvider {
    let id: ProviderID = .glm
    static let backoffKey = "glm-quota-limit"
    static let chinaHost = "open.bigmodel.cn"
    static let internationalHost = "api.z.ai"

    let session: URLSession
    /// 429 之后按接口退避；真 app 传落盘的 `QuotaBackoff.shared`。
    let backoff: QuotaBackoff
    let credentials: @Sendable () async -> ProviderCredentials
    let claudeSettings: URL
    let zcodeConfig: URL
    let opencodeAuth: URL

    static var defaultZcodeConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode/v2/config.json")
    }
    static var defaultOpencodeAuth: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/auth.json")
    }

    private static let manualSource = "手填"
    private static let authMessage = "GLM key 无效，或填错了区（国内 / 国际）"
    private static let throttledMessage = "GLM 用量接口限流，稍后自动再试"

    init(session: URLSession = URLSession(configuration: .ephemeral),
         backoff: QuotaBackoff = QuotaBackoff(),
         credentials: @escaping @Sendable () async -> ProviderCredentials = { await MainActor.run { ProviderCredentialsStore.shared.credentials } },
         claudeSettings: URL = CredentialDiscovery.claudeSettingsFile,
         zcodeConfig: URL = GLMUsageProvider.defaultZcodeConfig,
         opencodeAuth: URL = GLMUsageProvider.defaultOpencodeAuth) {
        self.session = session
        self.backoff = backoff
        self.credentials = credentials
        self.claudeSettings = claudeSettings
        self.zcodeConfig = zcodeConfig
        self.opencodeAuth = opencodeAuth
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        let manual = await credentials()
        guard let found = Self.resolveCredential(manual, claudeSettings: claudeSettings, zcodeConfig: zcodeConfig, opencodeAuth: opencodeAuth) else {
            throw UsageError.notConfigured("没有 GLM 的 key：在设置「用量」里填一个，或在 Claude Code 里配好 GLM")
        }
        // 退避期间不打接口：往限流里接着撞只会被限得更久
        guard backoff.allows(Self.backoffKey, now: now) else { throw UsageError.notFound(Self.throttledMessage) }

        // host 只可能是上面两个常量之一（手填按区选、本机查找只认这两个主机名），强解包不会炸
        var request = URLRequest(url: URL(string: "https://\(found.host)/api/monitor/usage/quota/limit")!)
        // 默认 60 秒：代理卡住时这一行要转一分钟，和 Claude、Codex 一样钉 10 秒
        request.timeoutInterval = 10
        // key 原样放，不加「Bearer」：codenotch #71 / #73 实测原样就行
        request.setValue(found.token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode ?? -1 {
        case 200..<300:
            break
        case 401, 403:
            throw UsageError.notConfigured(Self.authMessage)
        case 429:
            backoff.throttled(Self.backoffKey, now: now, retryAfter: http.flatMap { QuotaBackoff.retryAfter($0) })
            throw UsageError.notFound(Self.throttledMessage)
        case let status:
            throw UsageError.notFound("GLM 用量接口 HTTP \(status)")
        }
        // 信封里报错也说明接口在正常应答、没在限流，退避照样清掉
        backoff.succeeded(Self.backoffKey)
        return try Self.snapshot(from: data, now: now)
    }

    // MARK: 解析

    private struct Reply: Decodable {
        struct Payload: Decodable {
            let level: String?
            let limits: [Limit]?
        }
        struct Limit: Decodable {
            let type: String?
            let unit: Int?
            let number: Int?
            let usage: Double?
            let currentValue: Double?
            let percentage: Double?
            /// 毫秒。
            let nextResetTime: Double?
        }
        let code: Int?
        let success: Bool?
        let msg: String?
        let data: Payload?
    }

    /// 出错也回 HTTP 200，错误写在信封的 `code` / `success` / `msg` 里，所以先看信封再信数据。
    /// 窗口按 (unit, number) 认、不按 type 认：按 token 计的套餐回 TOKENS_LIMIT，按额度计的回 CREDIT_LIMIT，窗口编码一样。
    /// unit 3 是小时、6 是周：(3, 5) 是 5 小时，(6, 1) 是一周。
    static func snapshot(from data: Data, now: Date) throws -> UsageSnapshot {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            Log.error("GLM 用量接口的响应解不开（\(data.count) 字节），格式可能变了")
            throw UsageError.notFound("GLM 用量接口的响应看不懂")
        }
        if reply.success == false || (reply.code.map { $0 != 200 } ?? false) {
            throw envelopeError(code: reply.code, message: reply.msg)
        }
        var snapshot = UsageSnapshot()
        // TIME_LIMIT 是每月的 MCP 调用额度，unit 5 × number 1 只是个记号不是时长，也没有重置时间，不是这两条配额
        for limit in reply.data?.limits ?? [] where limit.type != "TIME_LIMIT" {
            switch (limit.unit, limit.number) {
            case (3?, 5?) where snapshot.sessionLimit == nil:
                snapshot.sessionLimit = usageLimit(limit)
            case (6?, 1?) where snapshot.weekLimit == nil:
                snapshot.weekLimit = usageLimit(limit)
            default:
                break
            }
        }
        guard snapshot.sessionLimit != nil || snapshot.weekLimit != nil else {
            Log.error("GLM 用量接口没返回 5 小时 / 周配额，格式可能变了")
            throw UsageError.notFound("GLM 用量接口没返回 5 小时 / 周配额")
        }
        if let level = reply.data?.level { snapshot.plan = planName(level) }
        snapshot.lastUpdated = now
        return snapshot
    }

    /// 信封里的错误码转成人话。码是智谱自己的编号：1000–1005 在官方错误码表里都对应 HTTP 401（身份验证类）。
    /// 实测（Pulse）：key 形状不对 401、另一个区的 key 1000、没带头 1001；key 有效但账号没订阅是 500 +「当前用户不存在coding plan」。
    static func envelopeError(code: Int?, message: String?) -> UsageError {
        let msg = message ?? ""
        switch code {
        case .some(401), .some(403), .some(1000...1005):
            return .notConfigured(authMessage)
        // 500 是通用码，单看它像服务挂了、让人去查故障；只有这句话说明是账号没订阅
        case .some(500) where msg.lowercased().contains("coding plan"):
            return .notConfigured("这个账号没有 GLM Coding Plan")
        default:
            let detail = [code.map { String($0) }, message].compactMap { $0 }.joined(separator: " ")
            return .notFound("GLM 用量接口报错：\(detail)")
        }
    }

    /// 有计数就用计数：percentage 是整数，计数更细。有人报过计数可能会被去掉，所以只剩 percentage 也得能画。
    private static func usageLimit(_ limit: Reply.Limit) -> UsageLimit? {
        let resets = limit.nextResetTime.map { Date(timeIntervalSince1970: $0 / 1000) }
        if let current = limit.currentValue, let total = limit.usage, total > 0 {
            return UsageLimit(used: current, limit: total, resetsAt: resets)
        }
        return limit.percentage.map { UsageLimit(used: $0, limit: 100, resetsAt: resets) }
    }

    private static func planName(_ level: String) -> String? {
        let trimmed = level.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed.capitalized
    }

    // MARK: 凭据

    /// 找 key，第一个命中的算：设置里手填的 → Claude Code 设置 → ZCode → OpenCode。每条都带上它所属区的主机名。
    static func resolveCredential(_ manual: ProviderCredentials, claudeSettings: URL, zcodeConfig: URL, opencodeAuth: URL) -> CredentialDiscovery.Found? {
        if let key = nonEmpty(manual.glmKey) {
            return CredentialDiscovery.Found(token: key, host: manual.glmRegion == "intl" ? internationalHost : chinaHost, source: manualSource)
        }
        return CredentialDiscovery.claudeSettings(claudeSettings, hosts: [chinaHost, internationalHost])
            ?? zcodeCredential(zcodeConfig)
            ?? opencodeCredential(opencodeAuth)
    }

    /// ZCode 的 `config.json`：`provider` 下 `builtin:*-coding-plan` 条目的 `options.apiKey`，区看旁边 `options.baseURL` 的主机名。
    /// `enabled: false` 是用户关掉的账号，跳过；没写 enabled 算开着。按 id 排序再取：字典无序，两条都开着时每次得读到同一条。
    static func zcodeCredential(_ file: URL) -> CredentialDiscovery.Found? {
        guard let providers = jsonObject(file)?["provider"] as? [String: Any] else { return nil }
        for (id, value) in providers.sorted(by: { $0.key < $1.key }) {
            guard id.hasPrefix("builtin:"), id.hasSuffix("-coding-plan"),
                  let entry = value as? [String: Any], (entry["enabled"] as? Bool) != false,
                  let options = entry["options"] as? [String: Any],
                  let key = nonEmpty(options["apiKey"])
            else { continue }
            let baseHost = (options["baseURL"] as? String).flatMap { CredentialDiscovery.host(of: $0) }
            // 没写 baseURL 才看 id：codenotch 这时一律当国际区，国内那条的 key 就发去了 api.z.ai
            let china = baseHost.map { $0 == "bigmodel.cn" || $0.hasSuffix(".bigmodel.cn") } ?? (id.contains("bigmodel") || id.contains("zhipu"))
            return CredentialDiscovery.Found(token: key, host: china ? chinaHost : internationalHost, source: "ZCode 配置")
        }
        return nil
    }

    /// OpenCode 按 provider id 存 key，id 带 zhipu 的是国内区（models.dev：zhipuai-coding-plan 走 open.bigmodel.cn），其余国际区。
    /// Coding Plan 的 id 排前面：两种都配了的人，订了套餐的多半是 coding-plan 那个账号。
    static let opencodeProviderIDs = ["zai-coding-plan", "zhipuai-coding-plan", "zai", "z-ai", "z.ai", "glm", "zhipu", "zhipuai"]

    /// 条目是 `{"type":"api","key":"…"}`（opencode auth/index.ts 的 Api 形状）；codenotch 说旧版直接存过字符串，也认。
    /// OAuth 条目没有 key 字段，自然跳过。
    static func opencodeCredential(_ file: URL) -> CredentialDiscovery.Found? {
        guard let root = jsonObject(file) else { return nil }
        for id in opencodeProviderIDs {
            guard let key = nonEmpty(root[id]) ?? nonEmpty((root[id] as? [String: Any])?["key"]) else { continue }
            return CredentialDiscovery.Found(token: key, host: id.hasPrefix("zhipu") ? chinaHost : internationalHost, source: "OpenCode 凭据")
        }
        return nil
    }

    /// 设置页那一行：会用哪儿的 key、查哪个区；一个都没有就说该怎么办。
    static func describeCredentials(_ manual: ProviderCredentials,
                                    claudeSettings: URL = CredentialDiscovery.claudeSettingsFile,
                                    zcodeConfig: URL = GLMUsageProvider.defaultZcodeConfig,
                                    opencodeAuth: URL = GLMUsageProvider.defaultOpencodeAuth) -> String {
        guard let found = resolveCredential(manual, claudeSettings: claudeSettings, zcodeConfig: zcodeConfig, opencodeAuth: opencodeAuth) else {
            return "还没有 key：在下面填一个并选对区，或在 Claude Code、ZCode、OpenCode 里配好 GLM Coding Plan"
        }
        let region = found.host == internationalHost ? "国际区" : "国内区"
        // 措辞跟 DeepSeek、Kimi 那几行一致；来源名都以名词收尾（「Claude Code 设置」「ZCode 配置」），拼「里的 key」才顺
        let origin = found.source == manualSource ? "用手填的 key" : "用 \(found.source)里的 key"
        return "\(origin)（\(region) \(found.host)）"
    }

    private static func jsonObject(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 去掉首尾空白后非空才算：带换行的值塞进请求头会被 URLRequest 悄悄丢掉，请求就成了没带 key（Pulse 踩过）。
    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
