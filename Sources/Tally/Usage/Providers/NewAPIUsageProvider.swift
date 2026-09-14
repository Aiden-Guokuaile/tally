import Foundation

/// New API（one-api 一系的中转站）的账户余额。站点是各自部署的，本机没有能找的凭据：站点地址、个人设置里生成的访问令牌、
/// 用户 ID 三样都得手填。只有钱，没有配额窗口，也没有本地日志算花费。
struct NewAPIUsageProvider: UsageProvider {
    let id: ProviderID = .newapi
    static let backoffKey = "newapi-user-self"
    let session: URLSession
    /// 429 之后按接口退避；真 app 传落盘的 `QuotaBackoff.shared`。
    let backoff: QuotaBackoff
    /// 每轮现取：设置里改了地址或令牌，下一轮刷新就用新的，不用重建 provider。
    let credentials: @Sendable () async -> ProviderCredentials

    init(session: URLSession = URLSession(configuration: .ephemeral),
         backoff: QuotaBackoff = QuotaBackoff(),
         credentials: @escaping @Sendable () async -> ProviderCredentials = { await MainActor.run { ProviderCredentialsStore.shared.credentials } }) {
        self.session = session
        self.backoff = backoff
        self.credentials = credentials
    }

    /// 站点的计价设置（`/api/status`）：额度怎么折成钱、站点面板按什么单位显示。
    struct Pricing: Equatable {
        /// 多少额度算 1 美元；one-api 一系出厂是 500000。
        var quotaPerUnit: Double = 500_000
        /// 「USD」「CNY」「TOKENS」。站点设成自定义货币（CUSTOM）的也按 USD：底层记账单位就是美元，数不会错。
        var displayType = "USD"
        /// 1 美元折多少人民币，只有 CNY 用。
        var usdExchangeRate: Double? = nil
        /// quota_per_unit 是站点给的；false 时是按出厂值估的，界面要说一声。
        var fromSite = false
    }

    private static let invalidBaseURLHint = "New API 站点地址不对：要带 http:// 或 https://，比如 https://api.example.com"

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        let manual = await credentials()
        let baseText = manual.newapiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = manual.newapiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let userId = manual.newapiUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseText.isEmpty, !token.isEmpty, !userId.isEmpty else {
            throw UsageError.notConfigured("New API 还没填完：站点地址、访问令牌、用户 ID 都要")
        }
        guard let base = Self.normalizedBaseURL(baseText) else {
            throw UsageError.notConfigured(Self.invalidBaseURLHint)
        }
        // 冷却期里再打只会把退避越撞越长；计价设置也不取，免得一轮里还是碰了站点
        guard backoff.allows(Self.backoffKey, now: now) else {
            throw UsageError.notFound("New API 限流中，过会儿自动再查")
        }

        // 计价设置和余额并发取：/api/status 卡住时不该把余额也多拖 10 秒
        async let statusBody = publicStatus(base)

        var request = URLRequest(url: base.appendingPathComponent("api/user/self"))
        // 默认 60 秒：代理卡住时这一行要转一分钟，和别家一样钉 10 秒
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // v0.6 一代的鉴权中间件没有这个头直接拒；新版改成忽略它，所以一律带上（Atoll 没带，老站上查不到）
        request.setValue(userId, forHTTPHeaderField: "New-Api-User")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        if status == 429 {
            backoff.throttled(Self.backoffKey, now: now, retryAfter: http.flatMap(QuotaBackoff.retryAfter))
            throw UsageError.notFound("New API 限流（HTTP 429），过会儿自动再查")
        }
        let quota = try Self.userQuota(status: status, body: data, host: base.host() ?? baseText)
        backoff.succeeded(Self.backoffKey)

        let pricing = Self.pricing(fromStatus: await statusBody)
        var snapshot = UsageSnapshot()
        snapshot.balances = Self.balances(remaining: quota.remaining, used: quota.used, pricing: pricing)
        // 按 token 显示用不到换算比例，估错了也不影响数
        if !pricing.fromSite && pricing.displayType != "TOKENS" {
            snapshot.limitsNote = "站点没返回计价设置，按 $1 = 500000 额度算"
        }
        snapshot.lastUpdated = now
        return snapshot
    }

    /// `/api/status` 是公开接口，不带令牌。取不到（老站、反代挡了、网络抖）返回 nil 按出厂计价算：余额本身拿到了，不该因为这个整行失败。
    private func publicStatus(_ base: URL) async -> Data? {
        var request = URLRequest(url: base.appendingPathComponent("api/status"))
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")
        guard case let (data, response)? = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    /// 站点根地址。人们常把 OpenAI 兼容地址（带 /v1）整个贴进来，去掉；子路径部署（https://x.com/newapi）保留。
    /// 只留 scheme、主机、端口、路径：query、fragment 拼上 /api/... 会错位，地址里的账号密码也不该跟着请求发出去。
    /// 没写 scheme 的不猜 https：内网自建站常是 http，猜错了令牌就发到别的端口上去了。
    static func normalizedBaseURL(_ text: String) -> URL? {
        guard let parsed = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parsed.host, !host.isEmpty
        else { return nil }
        var path = parsed.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/v1") { path.removeLast(3) }
        while path.hasSuffix("/") { path.removeLast() }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = parsed.port
        components.percentEncodedPath = path
        return components.url
    }

    /// 解析 `/api/status` 的计价设置，缺哪个字段用哪个出厂值：老版 one-api 没有 quota_display_type，只有 display_in_currency 开关。
    static func pricing(fromStatus data: Data?) -> Pricing {
        var pricing = Pricing()
        guard let data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let site = object["data"] as? [String: Any]
        else { return pricing }
        if let perUnit = number(site["quota_per_unit"]), perUnit > 0 {
            pricing.quotaPerUnit = perUnit
            pricing.fromSite = true
        }
        if let type = (site["quota_display_type"] as? String)?.uppercased() {
            pricing.displayType = ["CNY", "TOKENS"].contains(type) ? type : "USD"
        } else if (site["display_in_currency"] as? Bool) == false {
            pricing.displayType = "TOKENS"
        }
        if let rate = number(site["usd_exchange_rate"]), rate > 0 {
            pricing.usdExchangeRate = rate
        }
        return pricing
    }

    /// 剩余与已用额度折成两笔，单位跟站点自己的显示设置走：用户在站点面板上看到多少，这里就是多少。
    static func balances(remaining: Double, used: Double, pricing: Pricing) -> [Balance] {
        let unit: (currency: String, perUnit: Double, rate: Double)
        switch (pricing.displayType, pricing.usdExchangeRate) {
        case ("TOKENS", _): unit = ("tokens", 1, 1)
        case ("CNY", let rate?): unit = ("CNY", pricing.quotaPerUnit, rate)
        // 站点说按人民币却没给汇率：不猜汇率，按美元显示至少数是对的
        default: unit = ("USD", pricing.quotaPerUnit, 1)
        }
        return [Balance(amount: remaining / unit.perUnit * unit.rate, currency: unit.currency),
                Balance(amount: used / unit.perUnit * unit.rate, currency: unit.currency, label: "已用")]
    }

    /// 解读 `/api/user/self`：`data.quota` 是剩余额度（总额是 quota + used_quota）。429 由调用方先处理，它要记退避。
    static func userQuota(status: Int, body: Data, host: String) throws -> (remaining: Double, used: Double) {
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (object?["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let succeeded = (200..<300).contains(status)
        // 鉴权中间件回 401 带 message（令牌无效、New-Api-User 对不上）；接口自己拒绝回 200 带 success:false（如账号被封）。
        // 两种都是填的东西或账号有问题，站点给的原话比我们猜的准
        if status == 401 || status == 403 || (succeeded && (object?["success"] as? Bool) == false) {
            throw UsageError.notConfigured("New API 访问令牌或用户 ID 不对：\(message.isEmpty ? "HTTP \(status)" : message)")
        }
        guard succeeded else {
            throw UsageError.notFound("New API 余额查询失败（HTTP \(status)）")
        }
        guard let user = object?["data"] as? [String: Any],
              let remaining = number(user["quota"]), let used = number(user["used_quota"])
        else {
            // 地址填错时常拿到站点首页或别家登录页的 HTML，照实说「不是 New API」比「解析失败」好懂
            throw UsageError.notFound("\(host) 返回的不是 New API 的数据，站点地址填对了吗")
        }
        return (remaining, used)
    }

    /// 设置页那一行说明：三样都填了就报站点和用户，让人一眼看出填的是哪个站；没填完就说还差什么。
    static func describeCredentials(_ manual: ProviderCredentials) -> String {
        let fields: [(name: String, value: String)] = [
            ("站点地址", manual.newapiBaseURL), ("访问令牌", manual.newapiToken), ("用户 ID", manual.newapiUserId),
        ]
        let missing = fields.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { $0.name }
        guard missing.isEmpty else { return "还没填：" + missing.joined(separator: "、") }
        guard let host = normalizedBaseURL(manual.newapiBaseURL)?.host() else { return invalidBaseURLHint }
        return "站点 \(host) · 用户 \(manual.newapiUserId.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    /// JSON 里的数字。Atoll 的解码器也收字符串形式的数字（有的站反代改过序列化），照着兼容。
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    }
}
