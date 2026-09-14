import CryptoKit
import Foundation

/// 问用户的 shell。app 自己只有 launchd 给的那点环境，用户的 PATH、CODEX_HOME 都得问出来。
enum LoginShell {

    /// 问一次 shell 最多等这么久：交互 shell 带 nvm 那类要一两秒，10 秒是给慢机器的余量。
    static let deadline: TimeInterval = 10

    /// 跑一条命令，把 stdout 按行拆开。启动脚本自己也往 stdout 写东西（主题、instant prompt 那类），
    /// 所以调用方靠标记或「是不是真能执行」来挑自己要的那行，别整段拿去用。
    /// `-lc` 是登录 shell，**不读 `.zshrc`**（zsh 只在交互时读它）；`-ilc` 才读，代价是慢一截。
    /// 有上限：`CodexHome` 在启动路径上问它，某台机器的启动脚本卡住、或起个后台进程一直占着 stdout，
    /// 原来的 `readDataToEndOfFile` 会把刘海挂得出不来；到点就用已经收到的那部分输出。
    static func lines(_ flags: String, _ command: String) -> [String] {
        let shell = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        guard let result = try? Subprocess.run(shell, [flags, command], deadline: Self.deadline) else { return [] }
        // 超时拿到的是半截：要找的那行可能没出来，调用方会退回默认（比如 codex 的家落回 ~/.codex），日志里得看得出是这里卡的
        if result.timedOut { Log.error("登录 shell \(flags) \(Int(Self.deadline)) 秒没跑完，只用已收到的输出") }
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// 挑出 `<marker>=<值>` 那行的值。
    static func value(_ lines: [String], marker: String) -> String? {
        lines.last { $0.hasPrefix(marker + "=") }
            .map { String($0.dropFirst(marker.count + 1)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// codex 的家。默认 `~/.codex`，但 `CODEX_HOME` 能把它指到别处——有人给终端 codex 单开一个家，
/// 好跟 ChatGPT 桌面版共用的那份隔开。hook 装哪儿、用量读哪儿、配额读谁的 auth.json 都得跟着它走，
/// 否则装了也白装：hook 写进 `~/.codex`，人家的会话在另一个家里跑，一条都收不到。
/// app 的环境里没有用户 shell 的变量，所以要问一次登录 shell（实测 10 ms 上下），一个进程只问一次。
enum CodexHome {

    static let url: URL = resolve(shellValue: LoginShell.value(LoginShell.lines("-lc", "echo TALLY_CODEX_HOME=$CODEX_HOME"),
                                                               marker: "TALLY_CODEX_HOME"))

    static func resolve(shellValue: String?) -> URL {
        let value = [ProcessInfo.processInfo.environment["CODEX_HOME"], shellValue]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let value else { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }
}

/// Claude Code 的家。默认 `~/.claude`，设了 `CLAUDE_CONFIG_DIR` 就整个搬过去：settings.json（hook 装哪儿）、projects/（用量日志）、
/// sessions/（打断判定）、.credentials.json、.claude.json 都跟着走，钥匙串里凭据那条的服务名也跟着变。做法同 `CodexHome`。
enum ClaudeHome {

    /// 原值，不规范化：钥匙串服务名按原字符串算哈希，带不带尾斜杠算出来不一样。
    static let rawValue: String? = resolveRaw(
        shellValue: LoginShell.value(LoginShell.lines("-lc", "echo TALLY_CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"), marker: "TALLY_CLAUDE_CONFIG_DIR"),
        recorded: HookHeartbeat.read(sessionsDirectory: PreferencesStore.directory.appendingPathComponent("sessions"), provider: "claude")?.claudeConfigDir)
    static var url: URL { SessionRecord.claudeHome(configDir: rawValue) }

    /// app 自己的环境优先（从终端启动时才有），再是登录 shell 问回来的，最后是 hook 上次记下的 Claude Code 真实环境
    /// （变量只写在 `.zshrc` 里时登录 shell 问不出来，不补这一层就会读错家）；空白当没设。
    static func resolveRaw(shellValue: String?, recorded: String? = nil) -> String? {
        [ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], shellValue, recorded]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// `.claude.json`（套餐名在里面）：没设时在家目录旁边的 `~/.claude.json`，设了在那个目录里面。
    static func globalConfig(_ raw: String?) -> URL {
        guard raw != nil else { return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json") }
        return SessionRecord.claudeHome(configDir: raw).appendingPathComponent(".claude.json")
    }

    /// 钥匙串里 OAuth 凭据那条的服务名：没设是「Claude Code-credentials」；设了接「-」加原值（NFC）sha256 的前 8 位十六进制，
    /// 设成 `~/.claude` 本身也加（Claude Code 2.1.270 的算法）。
    static func keychainService(_ raw: String?) -> String {
        let base = "Claude Code-credentials"
        guard let raw else { return base }
        let digest = SHA256.hash(data: Data(raw.precomposedStringWithCanonicalMapping.utf8))
        return base + "-" + digest.map { String(format: "%02x", $0) }.joined().prefix(8)
    }
}
