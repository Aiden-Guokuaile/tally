import Foundation

/// DeepSeek 开放平台的账户余额。只有钱：没有配额窗口、没有重置时间，也没有本地日志算花费。
struct DeepSeekUsageProvider: UsageProvider {
    let id: ProviderID = .deepseek
    static let backoffKey = "deepseek-balance"
    /// 只有一个全球站点，没有分区。
    static let host = "api.deepseek.com"
    let session: URLSession
    /// 429 之后按接口退避；真 app 传落盘的 `QuotaBackoff.shared`。
    let backoff: QuotaBackoff
    /// 每轮现取：设置里改了 key，下一轮刷新就用新的，不用重建 provider。
    let credentials: @Sendable () async -> ProviderCredentials
    let claudeSettings: URL

    /// key 从哪来，设置页据此说明「用的是哪一把」。
    enum KeySource: Equatable {
        case manual, claudeSettings
    }

    init(session: URLSession = URLSession(configuration: .ephemeral),
         backoff: QuotaBackoff = QuotaBackoff(),
         credentials: @escaping @Sendable () async -> ProviderCredentials = { await MainActor.run { ProviderCredentialsStore.shared.credentials } },
         claudeSettings: URL = CredentialDiscovery.claudeSettingsFile) {
        self.session = session
        self.backoff = backoff
        self.credentials = credentials
        self.claudeSettings = claudeSettings
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        let manual = await credentials()
        guard let key = Self.resolveKey(manual, claudeSettings: claudeSettings)?.key else {
            throw UsageError.notConfigured("没有 DeepSeek 的 key：在设置「用量」里填一个")
        }
        // 冷却期里再打只会把退避越撞越长
        guard backoff.allows(Self.backoffKey, now: now) else {
            throw UsageError.notFound("DeepSeek 限流中，过会儿自动再查")
        }
        var request = URLRequest(url: URL(string: "https://\(Self.host)/user/balance")!)
        // 默认 60 秒：代理卡住时这一行要转一分钟，和 Claude、Codex 一样钉 10 秒
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? -1
        switch status {
        case 200..<300:
            backoff.succeeded(Self.backoffKey)
            guard let snapshot = Self.parse(data, now: now) else {
                throw UsageError.notFound("DeepSeek 余额响应读不懂（HTTP \(status)）")
            }
            return snapshot
        case 401, 403:
            throw UsageError.notConfigured("DeepSeek key 无效或被停用（HTTP \(status)）")
        case 429:
            backoff.throttled(Self.backoffKey, now: now, retryAfter: http.flatMap(QuotaBackoff.retryAfter))
            throw UsageError.notFound("DeepSeek 限流（HTTP 429），过会儿自动再查")
        default:
            throw UsageError.notFound("DeepSeek 余额查询失败（HTTP \(status)）")
        }
    }

    /// 解析 `/user/balance`。金额是字符串；一个账户可能人民币、美元各有一笔，各显示各的，不能相加。
    /// 认不出的响应（不是对象、没有 balance_infos、一笔余额都读不出）返回 nil，由调用方带上 HTTP 状态报错。
    static func parse(_ data: Data, now: Date) -> UsageSnapshot? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let infos = object["balance_infos"] as? [[String: Any]]
        else { return nil }
        var snapshot = UsageSnapshot()
        // 读不出的金额跳过而不是记 0：显示「¥0.00」会让人以为真没钱了。接口哪天把金额改成数字也认
        snapshot.balances = infos.compactMap { info -> Balance? in
            guard let currency = info["currency"] as? String,
                  let total = (info["total_balance"] as? String).flatMap(Double.init) ?? (info["total_balance"] as? NSNumber)?.doubleValue
            else { return nil }
            return Balance(amount: total, currency: currency)
        }
        // 一笔都读不出（空数组、字段改名）：当认不出报红字。当成功返回的话这一行只剩名字，看不出是没钱还是没读到
        guard !snapshot.balances.isEmpty else { return nil }
        // 只听接口自己的判断：赠送余额、欠费宽限怎么算不公开，拿金额自己推会推错
        if (object["is_available"] as? Bool) == false {
            snapshot.limitsNote = "余额不足，调用会被拒"
        }
        snapshot.lastUpdated = now
        return snapshot
    }

    /// 手填的优先；没填再看 Claude Code 是不是配成了走 DeepSeek——那种配法里的 token 就是一把普通的 DeepSeek key。
    static func resolveKey(_ manual: ProviderCredentials, claudeSettings: URL) -> (key: String, source: KeySource)? {
        let typed = manual.deepseekKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return (key: typed, source: .manual) }
        guard let found = CredentialDiscovery.claudeSettings(claudeSettings, hosts: [host]) else { return nil }
        return (key: found.token, source: .claudeSettings)
    }

    /// 设置页那一行说明：用的是哪把 key，没有就说怎么补。
    static func describeCredentials(_ manual: ProviderCredentials, claudeSettings: URL = CredentialDiscovery.claudeSettingsFile) -> String {
        switch resolveKey(manual, claudeSettings: claudeSettings)?.source {
        case .manual: return "用手填的 key"
        case .claudeSettings: return "用 Claude Code 设置里的 key"
        case nil: return "还没有 key：在下面填一个，或在 Claude Code 里把 DeepSeek 配好"
        }
    }
}
