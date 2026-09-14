import Foundation

/// 两侧 hook 的注册器：改 `~/.claude/settings.json` 与 `~/.codex/hooks.json`，给 Codex 写信任哈希，报状态。
///
/// 只在用户点「安装」时动这些文件；每次改前留 `<原名>.tally-backup`。
enum HookSide: CaseIterable {
    case claude, codex

    var title: String {
        switch self {
        case .claude: return "Claude Code hook"
        case .codex: return "Codex hook"
        }
    }

    var events: [String] {
        switch self {
        case .claude: return ["SessionStart", "UserPromptSubmit", "Notification", "PostToolUse", "Stop", "SessionEnd"]
        case .codex: return ["SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd"]
        }
    }
}

enum HookStatus: Equatable {
    /// 六个事件下都恰好有一个 Tally 匹配组且命令等于期望值。
    case installed
    /// 至少一个事件下有 Tally 匹配组，但不满足 installed；关联值是人话说明。
    case pointsElsewhere(String)
    /// 六个事件下都没有 Tally 匹配组。
    case missing
}

struct CodexHookEntry: Equatable {
    let key: String
    let command: String
    let hash: String
    /// app-server 报的 trustStatus 是不是 trusted。移除 Tally 后只把原本信任的写回去，没信任过的不替用户做主。
    let trusted: Bool

    init(key: String, command: String, hash: String, trusted: Bool = true) {
        self.key = key
        self.command = command
        self.hash = hash
        self.trusted = trusted
    }
}

enum HookInstallError: LocalizedError, Equatable {
    case invalidJSON(String)
    case codexNotFound
    case appServerFailed(String)
    /// app 不在固定位置（磁盘映像里、或被 Gatekeeper 搬到 AppTranslocation 的临时副本）。
    case unstableLocation(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let path): return "\(path) 不是合法的 JSON 对象，没有改动它"
        case .codexNotFound: return "找不到 codex 命令：登录 shell、交互 shell 和常见安装目录里都没有。装了的话，把它所在目录写进 ~/.zprofile 的 PATH 再重试"
        case .appServerFailed(let why): return "codex app-server 没拿到信任哈希：\(why)"
        case .unstableLocation:
            return "先把 Tally 拖进「应用程序」再装 hook：现在跑的这份是系统给的临时副本（从磁盘映像或下载目录直接打开会这样），它的路径重启就没了，写进配置的 hook 会失效"
        }
    }
}

/// app 现在跑在哪儿——装 hook 前要判一下：hook 路径会被写进 `~/.claude/settings.json` 与 `~/.codex/hooks.json`，
/// 写进去一个临时路径，重启后两边的 agent 都会去调一个不存在的文件。
enum BundleLocation {
    /// Gatekeeper 的路径随机化：从 DMG 或下载目录直接打开时，app 被搬到
    /// `/private/var/folders/…/AppTranslocation/<UUID>/d/Tally.app` 跑，重启即失效。
    static func isUnstable(_ path: String) -> Bool {
        path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/")
    }
}

struct HookInstaller {

    let claudeSettings: URL
    let codexHooks: URL
    let codexConfig: URL
    /// tally-hook 可执行文件的绝对路径。
    let hookBinary: String
    let codexHashes: () throws -> [CodexHookEntry]

    init(claudeSettings: URL, codexHooks: URL, codexConfig: URL, hookBinary: String,
         codexHashes: @escaping () throws -> [CodexHookEntry]) {
        self.claudeSettings = claudeSettings
        self.codexHooks = codexHooks
        self.codexConfig = codexConfig
        self.hookBinary = hookBinary
        self.codexHashes = codexHashes
    }

    /// 真实路径 + 真实的 app-server 查询。
    static func live() -> HookInstaller {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let binary = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("tally-hook").path
            ?? "/Applications/Tally.app/Contents/MacOS/tally-hook"
        return HookInstaller(
            claudeSettings: home.appendingPathComponent(".claude/settings.json"),
            codexHooks: CodexHome.url.appendingPathComponent("hooks.json"),
            codexConfig: CodexHome.url.appendingPathComponent("config.toml"),
            hookBinary: binary,
            codexHashes: CodexAppServer.hookEntries
        )
    }

    // MARK: 期望值

    /// 路径带双引号，防以后 app 被放到带空格的目录。
    func expectedCommand(_ side: HookSide) -> String {
        let quoted = "\"\(hookBinary)\""
        return side == .codex ? quoted + " --provider codex" : quoted
    }

    private func file(for side: HookSide) -> URL {
        side == .claude ? claudeSettings : codexHooks
    }

    /// 「Tally 匹配组」= 只含一个 hook 且该 hook 的 command 含 claude-event.js 或 tally-hook 的匹配组。
    static func isTallyGroup(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]], hooks.count == 1,
              let command = hooks[0]["command"] as? String else { return false }
        return command.contains("claude-event.js") || command.contains("tally-hook")
    }

    private func expectedGroup(_ side: HookSide) -> [String: Any] {
        ["hooks": [["type": "command", "command": expectedCommand(side), "timeout": 5]]]
    }

    // MARK: 状态

    func status(_ side: HookSide) -> HookStatus {
        guard let root = try? Self.load(file(for: side)) else { return .missing }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let expected = expectedCommand(side)
        var anyTally = false
        var missingEvents: [String] = []
        var elsewhere: String?
        for event in side.events {
            let groups = hooks[event] as? [[String: Any]] ?? []
            let tally = groups.filter(Self.isTallyGroup)
            if tally.isEmpty {
                missingEvents.append(event)
                continue
            }
            anyTally = true
            let commands = tally.compactMap { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String }
            if tally.count != 1 || commands.first != expected {
                elsewhere = commands.first(where: { $0 != expected }) ?? "重复注册"
            }
        }
        if !anyTally { return .missing }
        if missingEvents.isEmpty, elsewhere == nil { return .installed }
        var reasons: [String] = []
        if !missingEvents.isEmpty { reasons.append("\(missingEvents.joined(separator: "、")) 未注册") }
        if let elsewhere { reasons.append("命令指向 \(elsewhere)") }
        return .pointsElsewhere(reasons.joined(separator: "；"))
    }

    // MARK: 安装

    /// 幂等。旧 Tally 匹配组原位替换（多个时第一个原位、其余删掉），没有就追加到事件数组末尾。
    func install(_ side: HookSide) throws {
        // 临时副本的路径写进配置就是坏的，宁可不写
        guard !BundleLocation.isUnstable(hookBinary) else { throw HookInstallError.unstableLocation(hookBinary) }
        let url = file(for: side)
        var root = try Self.load(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in side.events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var replaced = false
            groups = groups.compactMap { group in
                guard Self.isTallyGroup(group) else { return group }
                if replaced { return nil }
                replaced = true
                return expectedGroup(side)
            }
            if !replaced { groups.append(expectedGroup(side)) }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        try Self.backup(url)
        try Self.save(root, to: url)
        if side == .codex {
            do {
                try trustCodexEntries()
            } catch {
                // 哈希写不进去就等于没装：留一半会让状态页说「已安装」而 Codex 不跑它
                try Self.restore(url)
                throw error
            }
        }
    }

    // MARK: 移除

    /// 把六个事件下的 Tally 匹配组删掉，别的 hook 不动；事件数组空了就连键一起删。
    /// Codex 侧删掉后别的 hook 序号前移、信任哈希失效，所以重新拿一遍 hooks/list 把剩下的哈希都写回去。
    func uninstall(_ side: HookSide) throws {
        // 先记下移除前哪些 hook 是用户信任过的，改完只把这些写回去
        let trustedBefore = side == .codex ? Set(try codexHashes().filter(\.trusted).map(\.command)) : []
        let url = file(for: side)
        var root = try Self.load(url)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in side.events {
            guard var groups = hooks[event] as? [[String: Any]] else { continue }
            groups.removeAll(where: Self.isTallyGroup)
            if groups.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = groups }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try Self.backup(url)
        try Self.save(root, to: url)
        if side == .codex {
            do {
                try retrustCodexEntries(trustedCommands: trustedBefore)
            } catch {
                try Self.restore(url)
                throw error
            }
        }
    }

    /// 移除之后序号变了，把移除前信任过的那些按新序号重写哈希；没信任过的一条不碰。
    private func retrustCodexEntries(trustedCommands: Set<String>) throws {
        let entries = try codexHashes().filter { !$0.command.contains("tally-hook") && trustedCommands.contains($0.command) }
        guard !entries.isEmpty else { return }
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        for entry in entries {
            text = Self.patchTrust(in: text, key: entry.key, hash: entry.hash)
        }
        try Self.backup(codexConfig)
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    /// 同键已存在就就地改写 trusted_hash，没有才追加整块。
    private func trustCodexEntries() throws {
        let entries = try codexHashes().filter { $0.command.contains("tally-hook") }
        guard !entries.isEmpty else { throw HookInstallError.appServerFailed("hooks/list 里没有 tally-hook 的条目") }
        var text = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        for entry in entries {
            text = Self.patchTrust(in: text, key: entry.key, hash: entry.hash)
        }
        try Self.backup(codexConfig)
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    static func patchTrust(in text: String, key: String, hash: String) -> String {
        let header = "[hooks.state.\"\(key)\"]"
        var lines = text.components(separatedBy: "\n")
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) {
            var cursor = index + 1
            while cursor < lines.count {
                let line = lines[cursor].trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { break }
                if line.hasPrefix("trusted_hash") {
                    lines[cursor] = "trusted_hash = \"\(hash)\""
                    return lines.joined(separator: "\n")
                }
                cursor += 1
            }
            lines.insert("trusted_hash = \"\(hash)\"", at: index + 1)
            return lines.joined(separator: "\n")
        }
        var result = text
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        result += "\n\(header)\ntrusted_hash = \"\(hash)\"\n"
        return result
    }

    // MARK: 文件

    /// 不存在或 0 字节按 `{}`；存在但不是 JSON 对象就抛错，不覆盖。
    static func load(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        if data.isEmpty || String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HookInstallError.invalidJSON(url.path)
        }
        return object
    }

    static func save(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    static func backupURL(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension(url.pathExtension + ".tally-backup")
    }

    static func backup(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let backup = backupURL(url)
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: url, to: backup)
    }

    /// 后半步失败时把刚改的文件退回备份；原来没有文件就删掉新写的。
    static func restore(_ url: URL) throws {
        let backup = backupURL(url)
        if FileManager.default.fileExists(atPath: backup.path) {
            try Data(contentsOf: backup).write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: 手工步骤

    static func manualSteps(_ side: HookSide, hookBinary: String) -> String {
        let command = side == .codex ? "\"\(hookBinary)\" --provider codex" : "\"\(hookBinary)\""
        let file = side == .claude ? "~/.claude/settings.json" : CodexHome.url.appendingPathComponent("hooks.json").path
        var text = "在 \(file) 的 hooks 下，给 \(side.events.joined(separator: "、")) 各加一条：\n"
        text += "{ \"hooks\": [ { \"type\": \"command\", \"command\": \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\", \"timeout\": 5 } ] }\n"
        if side == .codex {
            text += "然后用 codex app-server 的 hooks/list 拿每条的 key 与 currentHash，写进 \(CodexHome.url.appendingPathComponent("config.toml").path)：\n[hooks.state.\"<key>\"]\ntrusted_hash = \"<currentHash>\"\n"
        }
        return text
    }
}

/// 通过 `codex app-server` 拿 hooks/list。协议见 ~/.codex/hooks/README.md「信任」一节。
enum CodexAppServer {

    /// 常见安装目录，shell 都问不出来时按顺序试。
    static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            + ["/.local/bin/codex", "/.bun/bin/codex", "/.cargo/bin/codex",
               "/.npm-global/bin/codex", "/.volta/bin/codex"].map { home + $0 }
    }

    /// 找 codex，并带回跑它要用的 PATH。三级找：登录 shell → 交互登录 shell → 常见安装目录。
    ///
    /// 要问 shell 是因为 app 自己只有 launchd 给的那几个系统目录。两级 shell 是因为登录 shell **不读 `.zshrc`**
    /// （zsh 只在交互时读），nvm、volta、改过 npm prefix 的机器把 PATH 写在那儿。
    /// PATH 要一起带回来：codex 常是 `#!/usr/bin/env node` 的脚本，而 node 不一定和 codex 同目录
    /// （实测有台机器 codex 在 `~/.local/bin`、node 在 `/usr/local/bin`），只补 codex 那层目录仍然是
    /// `env: node: No such file or directory`，报到界面上却成了「没拿到信任哈希」。
    static func resolve() throws -> (codex: String, path: String?) {
        var path: String?
        for flags in ["-lc", "-ilc"] {
            let found = probe(flags)
            if let shellPath = found.path { path = shellPath }   // 交互那次的 PATH 更全，后来的盖前面的
            if let codex = found.codex { return (codex, path) }
        }
        if let codex = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return (codex, path)
        }
        throw HookInstallError.codexNotFound
    }

    /// 一次 shell 调用同时问「codex 在哪」和「PATH 是什么」：交互 shell 起一次要一秒，不值当问两遍。
    /// codex 按行挑真能执行的那条（`codex` 被包成 shell 函数时 `command -v` 只回名字，正好滤掉），PATH 认标记。
    static func probe(_ flags: String) -> (codex: String?, path: String?) {
        let lines = LoginShell.lines(flags, "command -v codex; echo TALLY_PATH=$PATH")
        return (lines.last { FileManager.default.isExecutableFile(atPath: $0) },
                LoginShell.value(lines, marker: "TALLY_PATH"))
    }

    /// 跑 app-server 用的环境：shell 的 PATH 打头，再补上 codex 自己那层目录；
    /// CODEX_HOME 也要给，否则 app-server 读的是默认的 `~/.codex`，算出来的哈希对不上我们刚写的那份 hooks.json。
    static func environment(codex: String, path: String?, codexHome: URL = CodexHome.url) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let directory = (codex as NSString).deletingLastPathComponent
        environment["PATH"] = [directory, path, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        environment["CODEX_HOME"] = codexHome.path
        return environment
    }

    /// 等 id 为 2 的那条结果最多等这么久。app-server 起来要读配置、探远程控制状态，慢机器上几秒起步。
    static let deadline: TimeInterval = 20

    static func hookEntries() throws -> [CodexHookEntry] {
        let located = try resolve()
        let request = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"tally","version":"1"}}}
        {"jsonrpc":"2.0","id":2,"method":"hooks/list","params":{"cwds":["/tmp"]}}

        """
        // 边跑边读，读到 id 为 2 的那条就停。
        // 原来是「睡 4 秒 → 关 stdin → 等它自己退 → 一次性读」，两头都会坏事：
        // 慢机器上 4 秒还没答完就被 terminate；hook 多的机器输出超过管道缓冲（64 KB）会把 app-server 堵死，
        // 我们再 terminate，读到的是半截——两种都表现为「响应里没有 id 为 2 的结果」。
        // 读法交给 Subprocess：它的截止时间对「一声不吭」也生效，原来循环里的 availableData 会一直阻塞。
        let result = try Subprocess.run(URL(fileURLWithPath: located.codex), ["app-server"],
                                        environment: environment(codex: located.codex, path: located.path),
                                        input: Data(request.utf8), deadline: Self.deadline) { stdout in
            let text = String(decoding: stdout, as: UTF8.self)
            return text.contains("\"id\":2") || text.contains("\"id\": 2")
        }
        let output = String(decoding: result.stdout, as: UTF8.self)
        let errors = String(decoding: result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try parse(output)
        } catch let error as HookInstallError {
            // 把现场带上：只说「没有 id 为 2 的结果」的话，远端用户没法告诉我们到底发生了什么
            guard case .appServerFailed(let why) = error else { throw error }
            var detail = why
            if result.timedOut { detail += "；等了 \(Int(Self.deadline)) 秒没等到" }
            if !errors.isEmpty { detail += "；stderr：" + errors.prefix(200) }
            if output.isEmpty {
                detail += "；app-server 一个字节都没输出"
            } else {
                detail += "；收到 " + String(output.count) + " 字符，开头是 " + output.prefix(120)
            }
            throw HookInstallError.appServerFailed(detail)
        }
    }

    static func parse(_ output: String) throws -> [CodexHookEntry] {
        // 按解析出来的 id 判，不按 `"id":2` 这个子串：格式化过的响应（`"id": 2`）会漏掉
        for line in output.split(separator: "\n") where line.hasPrefix("{") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (object["id"] as? NSNumber)?.intValue == 2
            else { continue }
            // 这条就是回给 hooks/list 的：出错了要把它的话说出来，
            // 不然「不支持这个方法」会被报成「响应里没有 id 为 2 的结果」，谁也不知道发生了什么
            if let failure = object["error"] as? [String: Any] {
                let message = (failure["message"] as? String) ?? "\(failure)"
                throw HookInstallError.appServerFailed("hooks/list 返回错误：" + message)
            }
            guard let result = object["result"] as? [String: Any],
                  let data = result["data"] as? [[String: Any]]
            else { continue }
            var entries: [CodexHookEntry] = []
            for group in data {
                for hook in group["hooks"] as? [[String: Any]] ?? [] {
                    guard let key = hook["key"] as? String, let hash = hook["currentHash"] as? String else { continue }
                    let command = Self.command(in: hook)
                    entries.append(CodexHookEntry(key: key, command: command, hash: hash,
                                                  trusted: hook["trustStatus"] as? String == "trusted"))
                }
            }
            return entries
        }
        throw HookInstallError.appServerFailed("响应里没有 id 为 2 的结果")
    }

    /// 命令文本在 hook 对象里的位置随版本变，从整个对象里找字符串值。
    static func command(in hook: [String: Any]) -> String {
        if let direct = hook["command"] as? String { return direct }
        for value in hook.values {
            if let nested = value as? [String: Any], let found = nested["command"] as? String { return found }
        }
        return (try? JSONSerialization.data(withJSONObject: hook)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
