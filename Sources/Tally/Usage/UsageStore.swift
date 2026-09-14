import Foundation
import Observation

/// 四家用量的刷新与结果。替代 Atoll 的 LLMUsageManager，不用 Defaults。
@MainActor
@Observable
final class UsageStore {

    static let shared = UsageStore()

    enum Reason {
        case panelOpened, timer, manual
    }

    static let minInterval: TimeInterval = 60
    static let timerInterval: TimeInterval = 300
    /// 一轮刷新要等四家都回来；某家卡住（比如某个调用在等一个没人点的系统框）会让这一轮永远不结束，
    /// 超过这么久就放行下一轮，迟到的结果按轮次号丢掉。
    static let passCeiling: TimeInterval = 180
    /// 临时失败时沿用上一次真拿到的配额，最多沿用这么久。
    nonisolated static let carryOverLimit: TimeInterval = 24 * 3600
    /// 沿用超过这么久还没拿到新读数，就在那一行说一声：一两次失败不值得红字，一直读不到（接口改版、登录失效）得让人知道。
    nonisolated static let staleNoteAfter: TimeInterval = 30 * 60

    /// 只含已开启的提供方；开启后第一次刷新完成前是 `.loading`。
    private(set) var results: [ProviderID: UsageResult] = [:]
    private(set) var isRefreshing = false
    /// 上一次刷新开始的时刻，界面显示「更新于」。
    private(set) var lastRefreshed: Date?

    /// 某家上一次真拿到（不是沿用、不是陈旧缓存）的配额。
    struct LiveLimits: Equatable {
        var session: UsageLimit?
        var week: UsageLimit?
        var at: Date
    }

    private let allProviders: [UsageProvider]
    private let clock: () -> Date
    private let preferences: () -> Preferences
    private var lastRefreshStart: Date?
    private var timer: Timer?
    private var liveLimits: [ProviderID: LiveLimits] = [:]
    /// 刷新轮次号：放行卡住的那一轮之后，它迟到的结果不许再写。
    private var generation = 0

    /// 默认用真实提供方与 PreferencesStore；测试注入假的。
    init(
        providers: [UsageProvider]? = nil,
        clock: @escaping () -> Date = Date.init,
        preferences: (() -> Preferences)? = nil
    ) {
        let scopedBox = ClaudeUsageProvider.ScopedLimitsBox()
        self.allProviders = providers ?? [
            ClaudeUsageProvider(scopedBox: scopedBox), CodexUsageProvider(), AntigravityUsageProvider(), CursorUsageProvider(),
        ]
        // 按模型分的周窗口是后台取的，取到就直接补进已有快照，不用等下一轮刷新
        scopedBox.setOnUpdate { scoped in
            Task { @MainActor in UsageStore.shared.applyClaudeScopedLimits(scoped) }
        }
        self.clock = clock
        self.preferences = preferences ?? { PreferencesStore.shared.prefs }
    }

    /// 后台取到按模型分的周窗口时补进 Claude 那条快照，不重新解析日志。
    func applyClaudeScopedLimits(_ scoped: [ScopedLimit]) {
        guard case .success(var snapshot)? = results[.claude], snapshot.scopedLimits != scoped else { return }
        snapshot.scopedLimits = scoped
        results[.claude] = .success(snapshot)
    }

    /// 退出前把扫描缓存写盘，省得下次启动白扫一遍。
    func flushScanCaches() {
        for provider in allProviders {
            (provider as? ClaudeUsageProvider)?.scan.flush()
            (provider as? CodexUsageProvider)?.scan.flush()
        }
    }

    func start() {
        providersChanged()
        timer = Timer.scheduledTimer(withTimeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: .timer) }
        }
        refresh(reason: .timer)
    }

    private var enabledProviders: [UsageProvider] {
        let prefs = preferences()
        return allProviders.filter { prefs[keyPath: $0.id.enabledKey] }
    }

    /// 开关变化：关掉的立刻从结果里消失，新开的置 loading 并立刻单独刷一次。
    /// 单独刷不占 60 秒节流也不碰 `isRefreshing`：不然要等下一轮（最长 5 分钟）一直「加载中」。
    /// 还一次都没刷过时不单独刷，马上那一轮会带上它。
    func providersChanged() {
        let enabled = enabledProviders
        let ids = Set(enabled.map(\.id))
        results = results.filter { ids.contains($0.key) }
        let added = enabled.filter { results[$0.id] == nil }
        for provider in added {
            results[provider.id] = .loading
        }
        guard lastRefreshStart != nil, !added.isEmpty else { return }
        Task { await runRefresh(providers: added, pass: nil) }
    }

    /// 三种理由都受 60 秒最短间隔约束，被跳过的调用不重置计时。返回 false 表示被跳过。
    @discardableResult
    func refresh(reason: Reason) -> Bool {
        guard beginRefreshIfAllowed() else { return false }
        let providers = enabledProviders
        let pass = generation
        Task { await runRefresh(providers: providers, pass: pass) }
        return true
    }

    /// 测试用：同步等刷新跑完。
    func refreshAndWait(reason: Reason) async -> Bool {
        guard beginRefreshIfAllowed() else { return false }
        await runRefresh(providers: enabledProviders, pass: generation)
        return true
    }

    private func beginRefreshIfAllowed() -> Bool {
        let now = clock()
        if let last = lastRefreshStart, now.timeIntervalSince(last) < Self.minInterval { return false }
        if isRefreshing, let last = lastRefreshStart, now.timeIntervalSince(last) < Self.passCeiling { return false }
        lastRefreshStart = now
        lastRefreshed = now
        isRefreshing = true
        generation += 1
        return true
    }

    /// 各家并发，各自失败各自报，不覆盖别家的成功结果。`pass` 是这一轮的轮次号，已被放行的旧轮次写不进来；
    /// nil 是开启某家时的单独刷新，不管轮次。
    private func runRefresh(providers: [UsageProvider], pass: Int?) async {
        let now = clock()
        await withTaskGroup(of: (ProviderID, UsageResult).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.id, .success(try await provider.fetchSnapshot(now: now))) }
                    catch { return (provider.id, .failure(error.localizedDescription)) }
                }
            }
            for await (id, result) in group where results[id] != nil && (pass == nil || pass == generation) {
                if case .success(let snapshot) = result, !snapshot.limitsStale,
                   snapshot.sessionLimit != nil || snapshot.weekLimit != nil {
                    liveLimits[id] = LiveLimits(session: snapshot.sessionLimit, week: snapshot.weekLimit, at: now)
                }
                results[id] = Self.carryOver(result, previous: results[id], live: liveLimits[id], now: now)
            }
        }
        if let pass, pass == generation { isRefreshing = false }
    }

    /// 这一轮没拿到配额（失败，或成功但两条都是 nil）而此前 24 小时内真拿到过：沿用那次的配额并标「~」，
    /// 这一轮的提示照常显示（失败的错误文本当提示）。临时断网、一次 429 不该让配额条消失成一行红字。
    /// 没有提示而沿用超过 30 分钟，就补一句「配额已 N 分钟没更新」，一直读不到时不至于只剩个「~」。
    /// 已过重置时间的窗口不沿用，一条都沿用不了就照实返回。
    nonisolated static func carryOver(_ result: UsageResult, previous: UsageResult?, live: LiveLimits?, now: Date) -> UsageResult {
        guard let live, now.timeIntervalSince(live.at) <= carryOverLimit else { return result }
        let session = live.session.flatMap { $0.isExpired(at: now) ? nil : $0 }
        let week = live.week.flatMap { $0.isExpired(at: now) ? nil : $0 }
        guard session != nil || week != nil else { return result }
        var snapshot: UsageSnapshot
        switch result {
        case .success(let fresh) where fresh.sessionLimit == nil && fresh.weekLimit == nil:
            snapshot = fresh
        case .failure(let message):
            guard case .success(let last)? = previous else { return result }
            snapshot = last
            snapshot.limitsNote = message
        default:
            return result
        }
        snapshot.sessionLimit = session
        snapshot.weekLimit = week
        snapshot.limitsStale = true
        let age = now.timeIntervalSince(live.at)
        if snapshot.limitsNote == nil, age >= staleNoteAfter {
            snapshot.limitsNote = age < 3600 ? "配额已 \(Int(age / 60)) 分钟没更新" : "配额已 \(Int(age / 3600)) 小时没更新"
        }
        return .success(snapshot)
    }
}
