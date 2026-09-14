// 移植自 Atoll（https://github.com/Ebullioscopic/Atoll），Copyright (C) 2024-2026 Atoll Contributors，GPL-3.0，见仓库 LICENSE 与 NOTICE。
// Tally 改动：配额不再调会回写凭据的客户端；先读 statusline 缓存，没有或陈旧再用只读客户端；按模型分的周窗口只有接口有，单独按 10 分钟节流取；日志走 UsageScanCache 增量扫描；projects 与 .claude.json 跟着 ClaudeHome（CLAUDE_CONFIG_DIR）。
import Foundation

struct ClaudeUsageProvider: UsageProvider {
    let id: ProviderID = .claude
    let root: URL
    let limits: ClaudeLimitsCache
    let quota: ClaudeQuotaReadOnly
    /// 引用类型：provider 是 struct，被 UsageStore 存着复制来复制去，节流状态与扫描缓存都得挂在盒子里才留得住。
    let scopedBox: ScopedLimitsBox
    let scan: UsageScanCache

    init(root: URL = ClaudeHome.url.appendingPathComponent("projects"),
         limits: ClaudeLimitsCache = ClaudeLimitsCache(),
         quota: ClaudeQuotaReadOnly = ClaudeQuotaReadOnly(),
         scopedBox: ScopedLimitsBox = ScopedLimitsBox(),
         scan: UsageScanCache = UsageScanCache(name: "claude")) {
        self.root = root
        self.limits = limits
        self.quota = quota
        self.scopedBox = scopedBox
        self.scan = scan
    }

    /// 按模型分的周窗口（Fable 那条）只有官方接口给，statusline 缓存没有。缓存新鲜时也要每 10 分钟问一次接口
    /// 才拿得到它，其余时间沿用上一次的值——这个窗口按周走，差十分钟无所谓。
    /// 取成功隔 10 分钟再取；失败只隔 1 分钟——代理偶发 SSL 断连，等十分钟这条就一直不出现。
    /// 不管成没成都要记时间，否则 token 过期时会变成每次刷新都去读凭据。
    final class ScopedLimitsBox: @unchecked Sendable {
        static let interval: TimeInterval = 600
        static let retryInterval: TimeInterval = 60

        private let lock = NSLock()
        private var value: [ScopedLimit] = []
        private var nextFetch: Date = .distantPast
        private var onUpdate: (([ScopedLimit]) -> Void)?

        init() {}

        /// 后台那次取到值时叫一声，界面立刻补上这条，不用等下一轮刷新（进程刚起来时差 5 分钟太久）。
        func setOnUpdate(_ handler: @escaping ([ScopedLimit]) -> Void) {
            lock.withLock { onUpdate = handler }
        }

        func needsFetch(now: Date) -> Bool {
            lock.withLock { now >= nextFetch }
        }

        /// value 为 nil 表示这一轮没拿到，只记尝试时间。
        func record(_ value: [ScopedLimit]?, now: Date) {
            let handler: (([ScopedLimit]) -> Void)?
            let latest: [ScopedLimit]
            (handler, latest) = lock.withLock {
                nextFetch = now.addingTimeInterval(value == nil ? Self.retryInterval : Self.interval)
                if let value { self.value = value }
                return (onUpdate, self.value)
            }
            if value != nil { handler?(latest) }
        }

        var current: [ScopedLimit] { lock.withLock { value } }
    }

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw UsageError.notFound("没找到 \(root.path)：没装 Claude Code，或 CLAUDE_CONFIG_DIR 指到了别处")
        }
        let files = jsonlFiles(under: root)
        guard !files.isEmpty else { throw UsageError.notFound("No Claude usage logs found") }
        var snapshot = scan.aggregate(files: files, now: now)
        let cache = limits.read(now: now)
        let live: ClaudeQuotaResult?
        if Self.cacheIsFresh(cache) {
            // 缓存够用，两条配额不等网络。那条按模型分的窗口只有接口有，扔后台取，下一轮刷新才用上：
            // 1 GB 日志本来就要解析好几秒，再串一个网络往返（代理抽风时更久）整行会一直「加载中」。
            live = nil
            if scopedBox.needsFetch(now: now) {
                let box = scopedBox
                let client = quota
                Task.detached(priority: .utility) {
                    if case .limits(let fetched) = await client.fetch(now: Date()) {
                        box.record(fetched.scoped, now: Date())
                    } else {
                        box.record(nil, now: Date())
                    }
                }
            }
        } else {
            // 缓存本来就得问接口，顺带把那条窗口一起收了
            let result = await quota.fetch(now: now)
            live = result
            if case .limits(let fetched) = result {
                scopedBox.record(fetched.scoped, now: now)
            } else {
                scopedBox.record(nil, now: now)
            }
        }
        let resolved = Self.resolveLimits(cache: cache, live: live, now: now)
        snapshot.sessionLimit = resolved.session
        snapshot.weekLimit = resolved.week
        snapshot.limitsStale = resolved.stale
        snapshot.limitsNote = resolved.note
        // 盒子里沿用的是上一次取到的值，过了它自己的重置时间就不再算数
        snapshot.scopedLimits = scopedBox.current.filter { !$0.limit.isExpired(at: now) }
        snapshot.plan = Self.readPlanLabel()
        return snapshot
    }

    static func cacheIsFresh(_ cache: ClaudeLimits?) -> Bool {
        cache.map { !$0.isStale } ?? false
    }

    struct ResolvedLimits: Equatable {
        var session: UsageLimit?
        var week: UsageLimit?
        var stale: Bool
        var note: String?
    }

    /// 顺序：缓存新鲜 → 用缓存（`live` 是为那条按模型分的窗口顺带取的，不影响这两条）；
    /// 否则看只读客户端的结果：拿到就用；token 过期时标注并退回陈旧缓存；不可用时退回陈旧缓存，没有就两条都 nil。
    /// 不管哪条路，已过重置时间的窗口都丢掉：隔夜没开 Claude Code，缓存里还是昨天的 92%，那个窗口早就重置了。
    static func resolveLimits(cache: ClaudeLimits?, live: ClaudeQuotaResult?, now: Date) -> ResolvedLimits {
        func current(_ limit: UsageLimit?) -> UsageLimit? { limit.flatMap { $0.isExpired(at: now) ? nil : $0 } }
        if let cache, !cache.isStale {
            return ResolvedLimits(session: current(cache.session), week: current(cache.week), stale: false, note: nil)
        }
        switch live {
        case nil:
            return ResolvedLimits(session: current(cache?.session), week: current(cache?.week), stale: cache != nil, note: nil)
        case .limits(let live):
            return ResolvedLimits(session: current(live.session), week: current(live.week), stale: false, note: nil)
        case .tokenExpired:
            return ResolvedLimits(session: current(cache?.session), week: current(cache?.week), stale: cache != nil, note: "登录已过期，去 Claude Code 跑一轮")
        case .unavailable:
            return ResolvedLimits(session: current(cache?.session), week: current(cache?.week), stale: cache != nil, note: nil)
        }
    }

    private func jsonlFiles(under dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return en.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
    }

    /// Reads the subscription plan from the plaintext `oauthAccount` fields in `~/.claude.json`
    /// (not a credential, no token). Prefers `organizationRateLimitTier` (distinguishes Max 5x / 20x),
    /// falling back to `organizationType`. Returns nil if the file is missing or malformed, so the
    /// badge simply does not render — this is best-effort and never fails the snapshot.
    private static func readPlanLabel() -> String? {
        let url = ClaudeHome.globalConfig(ClaudeHome.rawValue)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = obj["oauthAccount"] as? [String: Any] else { return nil }
        // Prefer the rate-limit tier, but fall back to organizationType when it is
        // absent OR blank/whitespace (a present-but-empty string must not short-circuit
        // the fallback). Return nil if neither yields a non-empty label so the badge
        // isn't rendered as an empty capsule.
        let raw = [account["organizationRateLimitTier"], account["organizationType"]]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let raw else { return nil }
        let label = prettyPlan(raw)
        return label.isEmpty ? nil : label
    }

    /// "default_claude_max_5x" → "Max 5x"; "claude_max" → "Max"; "claude_pro" → "Pro".
    private static func prettyPlan(_ raw: String) -> String {
        var s = raw
        for prefix in ["default_claude_", "claude_", "default_"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        let parts = s.split(separator: "_").map { seg -> String in
            // Keep multiplier tokens like "5x" / "20x" as-is; capitalize the rest.
            if seg.range(of: "^[0-9]+x$", options: .regularExpression) != nil { return String(seg) }
            return seg.prefix(1).uppercased() + seg.dropFirst()
        }
        return parts.joined(separator: " ")
    }
}

enum UsageError: LocalizedError {
    case notFound(String)
    case notConfigured(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let m), .notConfigured(let m): return m
        }
    }
}
