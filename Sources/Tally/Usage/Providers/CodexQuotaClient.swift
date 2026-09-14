// 移植自 Atoll（https://github.com/Ebullioscopic/Atoll），Copyright (C) 2024-2026 Atoll Contributors，GPL-3.0，见仓库 LICENSE 与 NOTICE。
// Tally 改动：按 limit_window_seconds 把窗口分到 5 小时 / 7 天两个槽，而不是按 primary / secondary 的次序硬套（头部兜底同样按 window-minutes 分）；401 / 403 带回一句给界面看的提示，不然登录过期时只是静默少两条配额；请求超时 10 秒。
import Foundation
import os

// Codex/ChatGPT rate-limit usage from chatgpt.com/backend-api/wham/usage; request+response shape per OpenUsage.
struct CodexQuotaClient {
    private static let log = os.Logger(subsystem: "com.aiden.tally", category: "CodexQuota")
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    private struct AuthFile: Decodable {
        struct Tokens: Decodable {
            let accessToken: String
            let accountId: String?
        }
        let tokens: Tokens
    }

    private struct RateLimitWindow: Decodable {
        let usedPercent: Double
        let limitWindowSeconds: Double?
        let resetAt: Double?
        let resetAfterSeconds: Double?
    }

    private struct RateLimit: Decodable {
        let primaryWindow: RateLimitWindow?
        let secondaryWindow: RateLimitWindow?
    }

    private struct UsageResponse: Decodable {
        let rateLimit: RateLimit?
    }

    // Never throws: any credential/network/parse failure yields (nil, nil, note).
    func fetchLimits() async -> (session: UsageLimit?, week: UsageLimit?, note: String?) {
        guard let creds = loadCredentials() else {
            Self.log.notice("no credentials: auth.json/Keychain missing or unparseable")
            return (nil, nil, nil)
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        // 默认 60 秒：代理卡住时这一行要「加载中」一分钟，和 Claude 那边一样钉 10 秒
        request.timeoutInterval = 10
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")
        if let accountId = creds.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                Self.log.error("wham/usage HTTP \(code) — \(code == 401 || code == 403 ? "auth/credential" : "request") failure")
                return (nil, nil, Self.authNote(status: code))
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let now = Date()
            if let decoded = try? decoder.decode(UsageResponse.self, from: data) {
                let windows = [decoded.rateLimit?.primaryWindow, decoded.rateLimit?.secondaryWindow]
                    .compactMap { $0 }
                    .map { (seconds: $0.limitWindowSeconds, limit: limit(from: $0, now: now)) }
                let assigned = Self.assign(windows: windows)
                if assigned.session != nil || assigned.week != nil { return (assigned.session, assigned.week, nil) }
            }
            // 头部兜底也按窗口长分槽：只有 7 天窗口的账号，primary 就是那个 7 天窗口，按次序硬套又会贴成「5 小时」
            let fallback = Self.assign(windows: ["primary", "secondary"].compactMap { headerWindow(http, name: $0) })
            if fallback.session == nil && fallback.week == nil {
                Self.log.error("wham/usage 200 but no usage found — response shape may have changed (\(data.count) bytes)")
            }
            return (fallback.session, fallback.week, nil)
        } catch {
            Self.log.error("wham/usage request errored: \(error.localizedDescription, privacy: .public)")
            return (nil, nil, nil)
        }
    }

    /// 401 / 403 是凭据问题，界面要说人话（Codex 的 access_token 有效期 10 天，Tally 只读不刷新）。
    /// 网络断、5xx、响应变形不写提示：那些不是用户能动手解决的，跟 Claude 侧一致只留日志。
    static func authNote(status: Int) -> String? {
        (status == 401 || status == 403) ? "登录已过期，去 Codex 跑一轮" : nil
    }

    /// 按窗口长度分槽：不到 24 小时的进 session（界面标「5 小时」），24 小时以上的进 week（标「7 天」）。
    /// 实测本机账号只有一个 604800 秒的 primary_window，按次序硬套会把周配额贴成 5 小时。
    /// 长度缺失时沿用原次序：第一个进 session，第二个进 week。同槽出现两个时保留第一个。
    static func assign(windows: [(seconds: Double?, limit: UsageLimit)]) -> (session: UsageLimit?, week: UsageLimit?) {
        var session: UsageLimit?
        var week: UsageLimit?
        for (index, window) in windows.enumerated() {
            let isWeek = window.seconds.map { $0 >= 24 * 3600 } ?? (index == 1)
            if isWeek {
                if week == nil { week = window.limit }
            } else if session == nil {
                session = window.limit
            }
        }
        return (session, week)
    }

    private func limit(from window: RateLimitWindow, now: Date) -> UsageLimit {
        let resets = window.resetAt.map { Date(timeIntervalSince1970: $0) } ?? window.resetAfterSeconds.map { now.addingTimeInterval($0) }
        return UsageLimit(used: window.usedPercent, limit: 100, resetsAt: resets)
    }

    private func headerWindow(_ http: HTTPURLResponse, name: String) -> (seconds: Double?, limit: UsageLimit)? {
        guard let raw = http.value(forHTTPHeaderField: "x-codex-\(name)-used-percent"), let percent = Double(raw) else { return nil }
        let minutes = http.value(forHTTPHeaderField: "x-codex-\(name)-window-minutes").flatMap(Double.init)
        return (minutes.map { $0 * 60 }, UsageLimit(used: percent, limit: 100))
    }

    // auth.json ($CODEX_HOME, ~/.codex, ~/.config/codex), then Keychain "Codex Auth" holding the same JSON payload.
    private func loadCredentials() -> (accessToken: String, accountId: String?)? {
        for path in authPaths() {
            if let data = try? Data(contentsOf: path), let creds = parseAuth(data) { return creds }
        }
        guard let value = KeychainReader.genericPassword(service: "Codex Auth"),
              let creds = parseAuth(Data(value.utf8)) else { return nil }
        return creds
    }

    private func authPaths() -> [URL] {
        // Tally 改动：家目录统一由 CodexHome 定（问过登录 shell 的 CODEX_HOME），app 自己的环境里没有那个变量
        return [
            CodexHome.url.appendingPathComponent("auth.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/codex/auth.json"),
        ]
    }

    private func parseAuth(_ data: Data) -> (accessToken: String, accountId: String?)? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let parsed = try? decoder.decode(AuthFile.self, from: data) else { return nil }
        return (parsed.tokens.accessToken, parsed.tokens.accountId)
    }
}
