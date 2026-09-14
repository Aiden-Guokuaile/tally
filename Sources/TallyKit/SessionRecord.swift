import Foundation

/// 一个 agent 会话的状态，和 hook 写的 JSON 一一对应。app 读、hook 写，所以放在共用库里。
public struct SessionRecord: Codable, Equatable, Identifiable {

    public enum State: String, Codable {
        case running
        case waitingPermission = "waiting_permission"
        case waitingInput = "waiting_input"
        /// 在压缩上下文（PreCompact）：长会话要几十秒，不标出来看着像卡住。
        case compacting
        case done
        /// 会话已关闭（交互会话的 SessionEnd，或进程没了），留一行给人接着聊。
        case ended
    }

    public var sessionId: String
    /// `claude` 或 `codex`。老文件没有这个键，按 claude 处理。
    public var provider: String
    /// agent 本体进程的 pid，用来判会话还活不活着。hook 找不到时为 nil。
    public var pid: Int?
    /// hook 进程环境里的 `TERM_PROGRAM`，定位窗口时按它分派。
    public var term: String?
    /// agent 进程的控制终端，形如 `ttys003`。
    public var tty: String?
    public var state: State
    /// 会话启动时的目录：定位窗口要的是 shell 所在目录，hook 收到的 cwd 会跟着会话里的 cd 走，所以只记第一次的。
    public var cwd: String
    public var title: String?
    public var transcriptPath: String
    public var message: String?
    /// 毫秒时间戳。
    public var updatedAt: Double
    /// 会话在用的模型 id，如 `claude-opus-5`、`gpt-6-astra`；还不知道时为 nil。来源见 `HookRunner`。
    public var model: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case provider
        case pid
        case term
        case tty
        case state
        case cwd
        case title
        case transcriptPath = "transcript_path"
        case message
        case updatedAt = "updated_at"
        case model
    }

    public init(sessionId: String, provider: String = "claude", pid: Int? = nil, term: String? = nil, tty: String? = nil,
                state: State, cwd: String, title: String?, transcriptPath: String, message: String?, updatedAt: Double,
                model: String? = nil) {
        self.sessionId = sessionId
        self.provider = provider
        self.pid = pid
        self.term = term
        self.tty = tty
        self.state = state
        self.cwd = cwd
        self.title = title
        self.transcriptPath = transcriptPath
        self.message = message
        self.updatedAt = updatedAt
        self.model = model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "claude"
        pid = try c.decodeIfPresent(Int.self, forKey: .pid)
        term = try c.decodeIfPresent(String.self, forKey: .term)
        tty = try c.decodeIfPresent(String.self, forKey: .tty)
        state = try c.decode(State.self, forKey: .state)
        cwd = try c.decode(String.self, forKey: .cwd)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        transcriptPath = try c.decodeIfPresent(String.self, forKey: .transcriptPath) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }

    /// 可空字段一律写成显式 null，不省键：契约里说每个键都在，读的一方靠键存在判格式版本。
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(provider, forKey: .provider)
        try c.encode(pid, forKey: .pid)
        try c.encode(term, forKey: .term)
        try c.encode(tty, forKey: .tty)
        try c.encode(state, forKey: .state)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(title, forKey: .title)
        try c.encode(transcriptPath, forKey: .transcriptPath)
        try c.encode(message, forKey: .message)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(model, forKey: .model)
    }

    public var id: String { sessionId }

    public var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    public var isClaude: Bool { provider == "claude" }

    /// 行里的提供方标签。
    public var providerLabel: String { provider == "codex" ? "Codex" : "Claude" }

    /// 行里的模型短名，还不知道模型时为 nil。
    public var modelLabel: String? { model.map(Self.shortModelName) }

    /// `claude-opus-5` →「Opus 5」、`claude-fable-5-1` →「Fable 5.1」、`claude-haiku-4-5-20251001` →「Haiku 4.5」、
    /// 老式的 `claude-3-5-sonnet-20241022` →「Sonnet 3.5」。别家的原样用（`gpt-6-astra`），不去猜它的营销名。
    public static func shortModelName(_ raw: String) -> String {
        var parts = raw.split(separator: "-").map(String.init)
        guard parts.first == "claude", parts.count >= 2 else { return raw }
        parts.removeFirst()
        // 末尾 8 位数字是发布日期
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        let words = parts.filter { Int($0) == nil }
        let version = parts.filter { Int($0) != nil }.joined(separator: ".")
        guard let family = words.first else { return raw }
        let name = [family.prefix(1).uppercased() + family.dropFirst()] + words.dropFirst()
        return (name + (version.isEmpty ? [] : [version])).joined(separator: " ")
    }

    /// 等审批或等输入。
    public var isWaiting: Bool {
        state == .waitingPermission || state == .waitingInput
    }

    /// 非 done / ended 且两小时没动静。跑完了、关掉了的会话不算失联。
    public func isStale(now: Date) -> Bool {
        state != .done && state != .ended && now.timeIntervalSince(updatedDate) > 2 * 3600
    }

    /// 会话列表的三组，按原始值从小到大排。
    public enum Group: Int, CaseIterable {
        case waiting, working, recent
    }

    public func group(now: Date) -> Group {
        if isStale(now: now) { return .recent }
        switch state {
        case .waitingPermission, .waitingInput: return .waiting
        case .running, .compacting: return .working
        case .done, .ended: return .recent
        }
    }

    /// 列表的显示顺序：等你 → 在跑 → 最近，组内按 updated_at 倒序，已关闭的排在最近组末尾。⌘1–⌘5 也按它数。
    public static func displayOrder(_ sessions: [SessionRecord], now: Date) -> [SessionRecord] {
        sessions.sorted { a, b in
            let ga = a.group(now: now), gb = b.group(now: now)
            if ga != gb { return ga.rawValue < gb.rawValue }
            if (a.state == .ended) != (b.state == .ended) { return b.state == .ended }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.sessionId < b.sessionId
        }
    }

    /// 闭合态徽标计数用：在等我，且没失联。
    public func countsAsWaiting(now: Date) -> Bool {
        isWaiting && !isStale(now: now)
    }

    /// 标题为空时用 cwd 最后一段顶上。
    public var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return cwdLabel
    }

    /// cwd 最后一段；根目录显示 `/`。
    public var cwdLabel: String {
        let last = URL(fileURLWithPath: cwd).lastPathComponent
        return last.isEmpty ? "/" : last
    }

    /// 带 pid 的记录：进程不在了就是会话没了（SessionEnd 没来的那种）。
    public var processIsGone: Bool {
        guard let pid else { return false }
        return kill(pid_t(pid), 0) == -1 && errno == ESRCH
    }

    /// Claude Code 的家：`CLAUDE_CONFIG_DIR` 设了就是它，没有就 `~/.claude`。hook 从 Claude Code 继承环境，直接看得到；
    /// app 的环境里没有，由 app 里的 `ClaudeHome` 问登录 shell 再传进来。
    public static func claudeHome(configDir: String?) -> URL {
        guard let configDir, !configDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
        return URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath)
    }

    public static func claudeSessionsDirectory(configDir: String?) -> URL {
        claudeHome(configDir: configDir).appendingPathComponent("sessions")
    }

    /// Claude Code 自己维护的 `<pid>.json` 里 `status` 是 busy / waiting / idle：回合一结束就写 idle，
    /// 打断和 API 报错（这两种不发 Stop）也写，等审批写 waiting。pid 会被系统复用，对上 sessionId 才算；
    /// 没有文件或字段（老版本、桌面版托管的会话）按不是 idle 算。
    public func claudeCodeReportsIdle(in directory: URL) -> Bool {
        guard let pid,
              let data = try? Data(contentsOf: directory.appendingPathComponent("\(pid).json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["sessionId"] as? String == sessionId && object["status"] as? String == "idle"
    }

    /// 超过 24 小时没更新的文件该删。活着但一天没事件的会话也会被清，
    /// 它下一次 UserPromptSubmit 会把文件重建。
    public static func orphans(files: [(url: URL, updatedAt: Date)], now: Date) -> [URL] {
        files.filter { now.timeIntervalSince($0.updatedAt) > 24 * 3600 }.map(\.url)
    }
}
