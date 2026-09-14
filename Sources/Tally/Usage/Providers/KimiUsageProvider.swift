import Foundation

/// Kimi 一行两块数据，账号和凭据都不相干，各查各的：
/// - Kimi Code 会员的 5 小时 / 周配额（api.kimi.com），填进两条配额条与套餐名；
/// - Kimi 开放平台的账户余额（api.moonshot.cn 或 .ai），填进余额。
/// 一块失败另一块照常显示，失败原因当提示；两块都没拿到才整行报错。
struct KimiUsageProvider: UsageProvider {
    let id: ProviderID = .kimi
    static let codeBackoffKey = "kimi-code-usages"
    static let balanceBackoffKey = "moonshot-balance"

    static let kimiCodeHost = "api.kimi.com"
    static let moonshotCNHost = "api.moonshot.cn"
    static let moonshotIntlHost = "api.moonshot.ai"
    static let codeUsageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    static let notConfiguredMessage = "没有 Kimi 的 key：在设置「用量」里填，或登录 Kimi Code"
    static let loginExpiredNote = "Kimi Code 登录过期：去 Kimi Code 跑一下"

    let session: URLSession
    /// 429 之后按接口退避；真 app 传落盘的 `QuotaBackoff.shared`。
    let backoff: QuotaBackoff
    let credentials: @Sendable () async -> ProviderCredentials
    let claudeSettings: URL
    /// Kimi Code CLI 的数据目录：环境变量 `KIMI_CODE_HOME`，没有就 ~/.kimi-code。
    let kimiCodeHome: URL

    init(session: URLSession = URLSession(configuration: .ephemeral), backoff: QuotaBackoff = QuotaBackoff(),
         credentials: @escaping @Sendable () async -> ProviderCredentials = { await MainActor.run { ProviderCredentialsStore.shared.credentials } },
         claudeSettings: URL = CredentialDiscovery.claudeSettingsFile,
         kimiCodeHome: URL = KimiUsageProvider.defaultKimiCodeHome) {
        self.session = session
        self.backoff = backoff
        self.credentials = credentials
        self.claudeSettings = claudeSettings
        self.kimiCodeHome = kimiCodeHome
    }

    static var defaultKimiCodeHome: URL {
        if let raw = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
    }

    // MARK: 凭据

    enum CredentialSource: Equatable {
        case manual, claudeSettings, kimiCodeLogin

        var text: String {
            switch self {
            case .manual: return "用设置里填的 key"
            case .claudeSettings: return "用 Claude Code 设置里的 key"
            case .kimiCodeLogin: return "用 Kimi Code 的登录"
            }
        }
    }

    struct CodeCredential: Equatable {
        let token: String
        let source: CredentialSource
        /// 只有 Kimi Code 登录那一档会过期。
        let expired: Bool
    }

    struct BalanceCredential: Equatable {
        let key: String
        let host: String
        let source: CredentialSource

        /// .cn 和 .ai 是两套账号，钱也是两种币：国内站人民币，国际站美元。
        var currency: String { host == KimiUsageProvider.moonshotIntlHost ? "USD" : "CNY" }
        var url: URL { URL(string: "https://\(host)/v1/users/me/balance")! }
    }

    /// 顺序：手填的 `sk-kimi-` key → Claude Code 设置里指向 api.kimi.com 的 key → Kimi Code CLI 的登录文件。
    /// 登录文件里的 access token 只活 15 分钟、由 CLI 自己刷新：这里只读，过期了也不刷新（抢着写会跟 CLI 撞文件），
    /// 交回去标成过期，不拿它发请求。
    static func codeCredential(_ manual: ProviderCredentials, claudeSettings: URL, kimiCodeHome: URL, now: Date) -> CodeCredential? {
        let key = manual.kimiCodeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return CodeCredential(token: key, source: .manual, expired: false) }
        if let found = CredentialDiscovery.claudeSettings(claudeSettings, hosts: [kimiCodeHost]) {
            return CodeCredential(token: found.token, source: .claudeSettings, expired: false)
        }
        let file = kimiCodeHome.appendingPathComponent("credentials/kimi-code.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (object["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty
        else { return nil }
        // expires_at 是秒；没有这个字段就当没过期，真过期了接口会回 401
        let expired = (object["expires_at"] as? NSNumber).map { $0.doubleValue <= now.timeIntervalSince1970 } ?? false
        return CodeCredential(token: token, source: .kimiCodeLogin, expired: expired)
    }

    /// 顺序：手填的开放平台 key（区由设置里选的定）→ Claude Code 设置里指向 api.moonshot.cn / .ai 的 key（找到的主机就是区）。
    static func balanceCredential(_ manual: ProviderCredentials, claudeSettings: URL) -> BalanceCredential? {
        let key = manual.moonshotKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            return BalanceCredential(key: key, host: manual.moonshotRegion == "intl" ? moonshotIntlHost : moonshotCNHost, source: .manual)
        }
        return CredentialDiscovery.claudeSettings(claudeSettings, hosts: [moonshotCNHost, moonshotIntlHost])
            .map { BalanceCredential(key: $0.token, host: $0.host, source: .claudeSettings) }
    }

    /// 设置页显示：两块各用的哪个凭据，没有就说怎么办。
    static func describeCredentials(_ manual: ProviderCredentials, claudeSettings: URL = CredentialDiscovery.claudeSettingsFile,
                                    kimiCodeHome: URL = KimiUsageProvider.defaultKimiCodeHome, now: Date = Date()) -> String {
        let code = codeCredential(manual, claudeSettings: claudeSettings, kimiCodeHome: kimiCodeHome, now: now)
        let balance = balanceCredential(manual, claudeSettings: claudeSettings)
        guard code != nil || balance != nil else { return notConfiguredMessage }
        let codeLine: String
        if let code {
            codeLine = code.expired ? loginExpiredNote : "Kimi Code 配额：\(code.source.text)"
        } else {
            codeLine = "Kimi Code 配额：没找到 key，填 sk-kimi- 开头的 key 或登录 Kimi Code"
        }
        let balanceLine: String
        if let balance {
            let region = balance.host == moonshotIntlHost ? "国际站，美元" : "国内站，人民币"
            balanceLine = "开放平台余额：\(balance.source.text)（\(region)）"
        } else {
            balanceLine = "开放平台余额：没找到 key，不查"
        }
        return codeLine + "\n" + balanceLine
    }

    // MARK: 取数

    struct Failure: Equatable {
        let message: String
        /// 用户能动手修的（key 不对、登录过期）。两块都失败时报这种，比「HTTP 500」有用。
        let actionable: Bool
    }

    struct CodeUsage: Equatable {
        var session: UsageLimit?
        var week: UsageLimit?
        var plan: String?
    }

    enum CodeOutcome: Equatable {
        case usage(CodeUsage)
        /// 404：这个账号没开 Kimi Code 会员。不是错。
        case noPlan
        case failed(Failure)
    }

    enum BalanceOutcome: Equatable {
        case balance(Balance)
        case failed(Failure)
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        let manual = await credentials()
        let code = Self.codeCredential(manual, claudeSettings: claudeSettings, kimiCodeHome: kimiCodeHome, now: now)
        let balance = Self.balanceCredential(manual, claudeSettings: claudeSettings)
        guard code != nil || balance != nil else { throw UsageError.notConfigured(Self.notConfiguredMessage) }
        // 两个接口互不相干，串行的话代理慢时整行要等两个超时
        async let codeOutcome = fetchCode(code, now: now)
        async let balanceOutcome = fetchBalance(balance, now: now)
        let (codeResult, balanceResult) = await (codeOutcome, balanceOutcome)
        return try Self.combine(code: codeResult, balance: balanceResult, now: now)
    }

    /// 至少一块拿到了就返回快照，另一块的失败当提示；一块都没拿到就抛，UsageStore 会沿用上一轮的配额并把这句当提示。
    static func combine(code: CodeOutcome?, balance: BalanceOutcome?, now: Date) throws -> UsageSnapshot {
        var snapshot = UsageSnapshot()
        snapshot.lastUpdated = now
        var failures: [Failure] = []
        var succeeded = false
        switch code {
        case .usage(let usage)?:
            snapshot.sessionLimit = usage.session
            snapshot.weekLimit = usage.week
            snapshot.plan = usage.plan
            succeeded = true
        case .noPlan?:
            succeeded = true
        case .failed(let failure)?:
            failures.append(failure)
        case nil:
            break
        }
        switch balance {
        case .balance(let value)?:
            snapshot.balances = [value]
            succeeded = true
        case .failed(let failure)?:
            failures.append(failure)
        case nil:
            break
        }
        let worst = failures.first(where: { $0.actionable }) ?? failures.first
        guard succeeded else {
            guard let worst else { throw UsageError.notConfigured(notConfiguredMessage) }
            throw worst.actionable ? UsageError.notConfigured(worst.message) : UsageError.notFound(worst.message)
        }
        if let worst {
            snapshot.limitsNote = worst.message
        } else if case .noPlan? = code, snapshot.balances.isEmpty {
            // 只填了 Kimi Code 的 key 却没会员：什么都不画的话这一行是空的，看不出是没取到还是没开
            snapshot.limitsNote = "这个账号没开 Kimi Code 会员"
        }
        return snapshot
    }

    private func fetchCode(_ credential: CodeCredential?, now: Date) async -> CodeOutcome? {
        guard let credential else { return nil }
        guard !credential.expired else { return .failed(Failure(message: Self.loginExpiredNote, actionable: true)) }
        // 429 退避期间不打接口：接着撞只会把退避越拉越长
        guard backoff.allows(Self.codeBackoffKey, now: now) else {
            return .failed(Failure(message: "Kimi Code 配额被限流，稍后再查", actionable: false))
        }
        let response: (data: Data, http: HTTPURLResponse)
        do {
            response = try await get(Self.codeUsageURL, bearer: credential.token)
        } catch {
            return .failed(Failure(message: "Kimi Code 配额没取到：\(error.localizedDescription)", actionable: false))
        }
        switch response.http.statusCode {
        case 200..<300:
            backoff.succeeded(Self.codeBackoffKey)
            guard let usage = Self.parseCodeUsage(response.data) else {
                return .failed(Failure(message: "Kimi Code 配额的返回看不懂", actionable: false))
            }
            return .usage(usage)
        case 404:
            return .noPlan
        case 401, 403:
            // 登录的 token 只活 15 分钟，被拒多半是刚过期、CLI 还没刷新；手填或 Claude Code 里的 key 被拒才是 key 本身不对
            let message = credential.source == .kimiCodeLogin ? Self.loginExpiredNote : "Kimi Code 的 key 无效"
            return .failed(Failure(message: message, actionable: true))
        case 429:
            backoff.throttled(Self.codeBackoffKey, now: now, retryAfter: QuotaBackoff.retryAfter(response.http))
            return .failed(Failure(message: "Kimi Code 配额被限流，稍后再查", actionable: false))
        default:
            return .failed(Failure(message: "Kimi Code 配额 HTTP \(response.http.statusCode)", actionable: false))
        }
    }

    private func fetchBalance(_ credential: BalanceCredential?, now: Date) async -> BalanceOutcome? {
        guard let credential else { return nil }
        guard backoff.allows(Self.balanceBackoffKey, now: now) else {
            return .failed(Failure(message: "Kimi 余额被限流，稍后再查", actionable: false))
        }
        let response: (data: Data, http: HTTPURLResponse)
        do {
            response = try await get(credential.url, bearer: credential.key)
        } catch {
            return .failed(Failure(message: "Kimi 余额没取到：\(error.localizedDescription)", actionable: false))
        }
        switch response.http.statusCode {
        case 200..<300:
            backoff.succeeded(Self.balanceBackoffKey)
            guard let amount = Self.parseBalance(response.data) else {
                return .failed(Failure(message: "Kimi 余额的返回看不懂", actionable: false))
            }
            return .balance(Balance(amount: amount, currency: credential.currency))
        case 401, 403:
            // 国内站的 key 拿去问国际站（或反过来）也是 401，最常见的原因是区选错了
            return .failed(Failure(message: "Kimi 开放平台的 key 无效（国内站、国际站不通用）", actionable: true))
        case 429:
            backoff.throttled(Self.balanceBackoffKey, now: now, retryAfter: QuotaBackoff.retryAfter(response.http))
            return .failed(Failure(message: "Kimi 余额被限流，稍后再查", actionable: false))
        default:
            return .failed(Failure(message: "Kimi 余额 HTTP \(response.http.statusCode)", actionable: false))
        }
    }

    private func get(_ url: URL, bearer: String) async throws -> (data: Data, http: HTTPURLResponse) {
        var request = URLRequest(url: url)
        // 默认 60 秒：代理卡住时这一行要「加载中」一分钟，和 Claude、Codex 一样钉 10 秒
        request.timeoutInterval = 10
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    // MARK: 解析

    /// 顶层 `usage` 是周窗口（响应里不写长度）；`limits[]` 各条自带窗口长度，挑正好 5 小时的那条。
    /// 数字都是字符串；`detail` 可能只给 `remaining` 不给 `used`。
    static func parseCodeUsage(_ data: Data) -> CodeUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let week = limit(from: object["usage"])
        let rows = object["limits"] as? [[String: Any]] ?? []
        let fiveHours = rows.first(where: { windowSeconds($0["window"]) == 5 * 3600 })
        let session = fiveHours.flatMap { limit(from: $0["detail"]) }
        guard session != nil || week != nil else { return nil }
        let membership = (object["user"] as? [String: Any])?["membership"] as? [String: Any]
        return CodeUsage(session: session, week: week, plan: planName(membership?["level"] as? String))
    }

    /// `{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"}` → 18000。不认识的单位给 nil：猜一个长度会把别的窗口贴成「5 小时」。
    static func windowSeconds(_ raw: Any?) -> Double? {
        guard let window = raw as? [String: Any], let duration = number(window["duration"]) else { return nil }
        switch (window["timeUnit"] as? String) ?? "" {
        case "TIME_UNIT_SECOND": return duration
        case "TIME_UNIT_MINUTE": return duration * 60
        case "TIME_UNIT_HOUR": return duration * 3600
        case "TIME_UNIT_DAY": return duration * 86400
        default: return nil
        }
    }

    /// "LEVEL_ADVANCED" → "Advanced"。认不得的等级也照样整理后显示：新出的档位有个名字总比没有强。
    static func planName(_ level: String?) -> String? {
        guard var name = level?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.hasPrefix("LEVEL_") { name.removeFirst("LEVEL_".count) }
        let words = name.split(separator: "_").map { word -> String in
            word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// `{"code":0,"data":{"available_balance":49.58894,…}}`。只显示可用余额：它 ≤ 0 就调不动了；现金余额可以是负的，不代表能不能用。
    static func parseBalance(_ data: Data) -> Double? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = object["data"] as? [String: Any]
        else { return nil }
        return (body["available_balance"] as? NSNumber)?.doubleValue
    }

    private static func limit(from raw: Any?) -> UsageLimit? {
        guard let detail = raw as? [String: Any], let total = number(detail["limit"]), total > 0 else { return nil }
        let derived = number(detail["remaining"]).map { max(total - $0, 0) }
        guard let used = number(detail["used"]) ?? derived else { return nil }
        return UsageLimit(used: used, limit: total, resetsAt: (detail["resetTime"] as? String).flatMap(ClaudeQuotaReadOnly.parseDate))
    }

    /// 实测是字符串；也收数字，接口哪天改回数字不至于整块取不到。
    private static func number(_ raw: Any?) -> Double? {
        if let text = raw as? String { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return (raw as? NSNumber)?.doubleValue
    }
}
