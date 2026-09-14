import Foundation

/// 演示模式的假数据：一眼看得出是编的，排出来又像真的。目录都在 /Users/demo 下，地址用文档专用段 192.0.2.0/24，
/// pid 从 macOS 上不可能出现的值起（上限 99999），拿去 kill(0)、NSRunningApplication 都碰不上真进程。
enum DemoData {

    static let firstPid = 999_999

    /// 启动后第一条提示条说的就是它。
    static let peekSessionId = "demo-payment-callback"

    // MARK: 设置

    /// 在默认值上改的几项，都是为了截图：
    static var preferences: Preferences {
        var prefs = Preferences()
        // 开着的话窗口服务器不给截屏工具读面板，截出来是空的
        prefs.hideFromCapture = false
        prefs.checkUpdates = false
        prefs.batteryPeek = false
        prefs.screenshotsToShelf = false
        // 没有刘海屏时提示改发系统通知，会去要通知授权
        prefs.notifyWithoutNotch = false
        // 摄像头 / 麦克风占用点读的是真设备状态：录屏时正开着会议的话，假界面里会冒出一个真图标
        prefs.privacyDots = false
        prefs.launchAtLogin = false
        prefs.hoverToOpen = true
        prefs.shelfEnabled = true
        // 恐龙只读整机 CPU 和内存，不涉隐私，露出来给截图看
        prefs.strideEnabled = true
        prefs.strideShowsValue = false
        // 用量条多一家才看得出能并排；再多一家 AI 页就超过面板最高的六成屏高，底部被裁
        prefs.enableDeepSeek = true
        prefs.lastPage = "ai"
        return prefs
    }

    // MARK: AI 页

    /// 等你两个、在跑两个、最近一个、已关闭两个；没关闭的都在两小时内动过，不会被画成失联。条数刚好让 AI 页放进面板最高高度。
    static func sessions(now: Date) -> [SessionRecord] {
        func ago(_ seconds: TimeInterval) -> Double { ((now.timeIntervalSince1970 - seconds) * 1000).rounded() }
        return [
            SessionRecord(sessionId: "demo-order-pagination", provider: "claude", pid: firstPid, term: "ghostty", tty: "ttys003",
                          state: .waitingPermission, cwd: "/Users/demo/code/shop-web", title: "给订单列表加分页", transcriptPath: "",
                          message: nil, updatedAt: ago(40), model: "claude-opus-5"),
            SessionRecord(sessionId: "demo-ci-migration", provider: "codex", pid: firstPid + 1, term: "tmux", tty: "ttys005",
                          state: .waitingInput, cwd: "/Users/demo/code/infra", title: "迁移 CI 到 GitHub Actions", transcriptPath: "",
                          message: nil, updatedAt: ago(4 * 60), model: "gpt-6-astra"),
            SessionRecord(sessionId: "demo-login-form", provider: "claude", pid: firstPid + 2, term: "ghostty", tty: "ttys004",
                          state: .running, cwd: "/Users/demo/code/shop-web", title: "重构登录页的表单校验", transcriptPath: "",
                          message: nil, updatedAt: ago(25), model: "claude-sonnet-5"),
            SessionRecord(sessionId: "demo-rate-limit", provider: "codex", pid: firstPid + 3, term: "iTerm.app", tty: "ttys006",
                          state: .running, cwd: "/Users/demo/code/api-server", title: "给接口加限流和重试", transcriptPath: "",
                          message: nil, updatedAt: ago(2 * 60), model: "gpt-6-astra"),
            SessionRecord(sessionId: peekSessionId, provider: "claude", pid: firstPid + 4, term: "ghostty", tty: "ttys002",
                          state: .done, cwd: "/Users/demo/code/api-server", title: "修复支付回调重复入账", transcriptPath: "",
                          message: "回调按订单号加了幂等键，重复通知不再入账，补了 3 个用例", updatedAt: ago(3 * 60), model: "claude-opus-5"),
            SessionRecord(sessionId: "demo-memory-leak", provider: "claude", state: .ended, cwd: "/Users/demo/code/api-server",
                          title: "排查内存泄漏", transcriptPath: "", message: nil, updatedAt: ago(3 * 3600), model: "claude-opus-5"),
            SessionRecord(sessionId: "demo-upgrade-deps", provider: "codex", state: .ended, cwd: "/Users/demo/code/shop-web",
                          title: "升级依赖到最新版", transcriptPath: "", message: nil, updatedAt: ago(20 * 3600), model: "gpt-6-astra"),
        ]
    }

    static var usageProviders: [UsageProvider] {
        [ProviderID.claude, .codex, .deepseek].map(DemoUsageProvider.init)
    }

    /// 数字固定，只有重置时刻跟着 `now` 走：刷多少轮都是同一副样子，配额条也不会因为过了重置时刻消失。
    static func snapshot(for id: ProviderID, now: Date) -> UsageSnapshot {
        func limit(_ percent: Double, resetsIn seconds: TimeInterval) -> UsageLimit {
            UsageLimit(used: percent, limit: 100, resetsAt: now.addingTimeInterval(seconds))
        }
        let claudeWeekReset: TimeInterval = 4 * 86400 + 2 * 3600
        var snapshot = UsageSnapshot()
        snapshot.lastUpdated = now
        switch id {
        case .claude:
            snapshot.plan = "Max"
            snapshot.today = UsageTotals(inputTokens: 1_690_000, outputTokens: 110_000, costUSD: 12.40)
            snapshot.week = UsageTotals(inputTokens: 12_900_000, outputTokens: 700_000, costUSD: 86.10)
            snapshot.sessionLimit = limit(42, resetsIn: 2 * 3600 + 10 * 60)
            // 7 天窗口才过去四成、已经用了六成：配速线变橙，截图里看得到这个功能
            snapshot.weekLimit = limit(61, resetsIn: claudeWeekReset)
            snapshot.scopedLimits = [ScopedLimit(label: "Fable", limit: limit(23, resetsIn: claudeWeekReset))]
        case .codex:
            snapshot.plan = "Pro"
            snapshot.today = UsageTotals(inputTokens: 2_150_000, outputTokens: 90_000, costUSD: 4.20)
            snapshot.week = UsageTotals(inputTokens: 14_800_000, outputTokens: 600_000, costUSD: 27.80)
            snapshot.sessionLimit = limit(18, resetsIn: 3 * 3600 + 40 * 60)
            snapshot.weekLimit = limit(35, resetsIn: 5 * 86400)
        case .deepseek:
            snapshot.balances = [Balance(amount: 128.50, currency: "CNY")]
        case .cursor, .antigravity, .kimi, .glm, .newapi:
            break
        }
        return snapshot
    }

    /// 第二条提示条：Claude 5 小时配额涨过 80%。
    static func quotaPeekEvent(now: Date) -> QuotaEvent {
        QuotaEvent(provider: .claude, window: ProviderID.claude.stripLabels.session, kind: .high(percent: 82),
                   resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60))
    }

    // MARK: 网络页

    static let interface = InterfaceInfo(name: "en0", address: "192.0.2.24", router: "192.0.2.1", dns: ["1.1.1.1", "8.8.8.8"],
                                         wifi: WiFiInfo(rssi: -48, noise: -92, transmitRate: 1200, channel: 149))

    /// 每秒一个点：几条周期不同的正弦叠起来，下行在 1–6 MB/s、上行在 100–600 KB/s 之间起伏，曲线是活的又不乱跳。
    static func throughput(at time: TimeInterval) -> (up: Int, down: Int) {
        let down = 3_700_000 + 1_600_000 * sin(time / 9) + 1_000_000 * sin(time / 2.7)
        let up = 360_000 + 150_000 * sin(time / 11 + 1) + 90_000 * sin(time / 3.1)
        return (Int(up), Int(down))
    }

    // MARK: 系统页

    private static let gib: UInt64 = 1 << 30
    private static let mib: UInt64 = 1 << 20

    static func hardware(now: Date) -> HardwareInfo {
        HardwareInfo(chip: "Apple M4 Pro", performanceCores: 10, efficiencyCores: 4, memoryTotal: 48 * gib, osVersion: "26.2",
                     bootTime: now.addingTimeInterval(-(3 * 86400 + 5 * 3600)))
    }

    static let systemSample = SystemSample(
        memoryUsed: 48 * gib * 58 / 100, memoryTotal: 48 * gib, cpuFraction: 0.23,
        battery: BatteryHealth(percent: 87, state: .discharging, healthPercent: 96, cycleCount: 142),
        diskAvailable: 412 * gib, diskTotal: 926 * gib, pressure: .normal,
        topProcesses: [
            ProcessMemory(name: "Xcode", bytes: 6_350 * mib),
            ProcessMemory(name: "Safari", bytes: 2_310 * mib),
            ProcessMemory(name: "Claude", bytes: 1_420 * mib),
        ]
    )

    static let trash = TrashInfo(count: 12, bytes: 1_331 * mib)

    // MARK: 应用页

    /// 每台 Mac 都有的系统 app：图标按 bundleURL 从磁盘取得到。已按内存降序排好，和真列表一个顺序。
    static let apps: [RunningApp] = [
        ("Safari浏览器", "/Applications/Safari.app", "com.apple.Safari", 2_870),
        ("邮件", "/System/Applications/Mail.app", "com.apple.mail", 612),
        ("音乐", "/System/Applications/Music.app", "com.apple.Music", 455),
        ("备忘录", "/System/Applications/Notes.app", "com.apple.Notes", 318),
        ("日历", "/System/Applications/Calendar.app", "com.apple.iCal", 196),
        ("预览", "/System/Applications/Preview.app", "com.apple.Preview", 142),
        ("终端", "/System/Applications/Utilities/Terminal.app", "com.apple.Terminal", 128),
    ].enumerated().map { index, app in
        RunningApp(id: pid_t(firstPid + 10 + index), name: app.0, bundleURL: URL(fileURLWithPath: app.1),
                   bundleIdentifier: app.2, isHidden: false, memory: UInt64(app.3) * mib)
    }

    // MARK: 文件架

    static func shelfItems(now: Date) -> [ShelfItem] {
        func item(_ id: String, _ name: String, _ size: Int64, minutesAgo: Double, _ kind: ShelfKind) -> ShelfItem {
            ShelfItem(id: id, name: name, size: size, addedAt: ((now.timeIntervalSince1970 - minutesAgo * 60) * 1000).rounded(),
                      source: nil, kind: kind)
        }
        return [
            item("demo-screenshot", "截屏 2026-09-14 下午3.12.08.png", 1_184_000, minutesAgo: 4, .screenshot),
            item("demo-design", "设计稿-首页.png", 2_536_000, minutesAgo: 12, .file),
            item("demo-checklist", "发布清单.md", 4_096, minutesAgo: 26, .file),
            item("demo-api-doc", "接口文档.pdf", 862_000, minutesAgo: 58, .file),
        ]
    }
}

/// 演示模式的用量提供方：不扫日志、不读凭据、不调接口，照 `DemoData.snapshot` 交数。
struct DemoUsageProvider: UsageProvider {
    let id: ProviderID

    func fetchSnapshot(now: Date) async throws -> UsageSnapshot {
        DemoData.snapshot(for: id, now: now)
    }
}
