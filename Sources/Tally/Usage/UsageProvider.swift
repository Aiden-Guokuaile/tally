// 移植自 Atoll（https://github.com/Ebullioscopic/Atoll），Copyright (C) 2024-2026 Atoll Contributors，GPL-3.0，见仓库 LICENSE 与 NOTICE。
// Tally 改动：去掉 Defaults 与 NewAPI；enabledKey 指向 Preferences；加 limitLabels、logoName、limitsStale 与 scopedLimits；UsageLimit 加 isExpired(at:)。
import Foundation

enum ProviderID: String, CaseIterable, Identifiable {
    case claude, codex, cursor, antigravity
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .antigravity: return "Antigravity"
        }
    }
    /// 用量行名字前的标志（`ProviderLogo` 的资源名）。Codex 用 OpenAI 的。
    var logoName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "openai"
        case .cursor: return "cursor"
        case .antigravity: return "antigravity"
        }
    }
    var enabledKey: WritableKeyPath<Preferences, Bool> {
        switch self {
        case .claude: return \.enableClaude
        case .codex: return \.enableCodex
        case .cursor: return \.enableCursor
        case .antigravity: return \.enableAntigravity
        }
    }
    /// 两条进度条的标签。四家的 sessionLimit / weekLimit 语义不同：
    /// Claude、Codex 是 5 小时 / 7 天窗口；Cursor 是两个模型池；Antigravity 是 Gemini / Claude 两个池。
    var limitLabels: (session: String, week: String) {
        switch self {
        case .claude, .codex: return ("5 小时", "7 天")
        case .cursor: return ("Cursor 模型", "其他模型")
        case .antigravity: return ("Gemini 池", "Claude 池")
        }
    }
    /// 一行放两条时用的短标签。
    var stripLabels: (session: String, week: String) {
        switch self {
        case .claude, .codex: return ("5 小时", "7 天")
        case .cursor: return ("Cursor", "其他")
        case .antigravity: return ("Gemini", "Claude")
        }
    }
}

/// 一条带名字的配额窗口：Claude 按模型分的周窗口用它，标签就是模型显示名。
struct ScopedLimit: Equatable {
    var label: String
    var limit: UsageLimit
}

struct UsageTotals: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var costUSD: Double = 0
    var hasUnpricedModel: Bool = false
    var isPercentage: Bool = false
    var totalTokens: Int { inputTokens + outputTokens }
}

struct ModelUsage: Equatable, Identifiable {
    let model: String
    let totals: UsageTotals
    let pool: String? // "gemini" or "claude" for Antigravity
    let resetsAt: Date? // quota reset time for percentage-based providers
    var id: String { model }

    init(model: String, totals: UsageTotals, pool: String? = nil, resetsAt: Date? = nil) {
        self.model = model
        self.totals = totals
        self.pool = pool
        self.resetsAt = resetsAt
    }
}

struct UsageLimit: Equatable {
    let used: Double
    let limit: Double
    var resetsAt: Date? = nil
    var fraction: Double { limit > 0 ? min(used / limit, 1) : 0 }
    /// 过了重置时间：这个窗口已经翻篇，手里的百分比说的是上一个窗口，不能再拿来显示。
    func isExpired(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
}

struct UsageSnapshot: Equatable {
    var session: UsageTotals = .init()
    var today: UsageTotals = .init()
    var week: UsageTotals = .init()
    var sessionLimit: UsageLimit? = nil // 5h window quota
    var weekLimit: UsageLimit? = nil // 7d window quota
    var models: [ModelUsage] = []
    var plan: String? = nil // Subscription plan label (e.g. "Max 5x"); provided by Claude only, nil otherwise.
    /// Claude 的配额来自 statusline 缓存，缓存陈旧时为 true，界面在百分比后加「~」。
    var limitsStale: Bool = false
    /// 配额取不到时给用户看的一句话（如「登录已过期」），nil 就不显示。
    var limitsNote: String? = nil
    /// 按模型分的周窗口（Claude 的 `weekly_scoped`，标签是模型名如「Fable」）；只有官方接口有，statusline 缓存没有。
    var scopedLimits: [ScopedLimit] = []
    var lastUpdated: Date = .distantPast
}

enum UsageResult {
    case loading
    case success(UsageSnapshot)
    case failure(String)
}

protocol UsageProvider {
    var id: ProviderID { get }
    func fetchSnapshot(now: Date) async throws -> UsageSnapshot
}
