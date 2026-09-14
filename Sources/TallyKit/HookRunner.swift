import Foundation

/// hook 的一次运行：校验、决策、找 pid / tty / term、读标题与模型、原子写文件。
///
/// 纯观测，三条硬约束由调用方（tally-hook 的 main）保证：永远 exit 0、900 ms 自退、
/// 校验不过不写文件。这里只负责「过了校验之后做什么」。
public struct HookOptions {
    public var provider: String
    public var directory: URL
    public var now: () -> Date
    public var environment: [String: String]
    /// 从哪个进程开始往上找 agent；默认是 hook 进程的父进程。
    public var startPid: Int32
    /// Claude Code 自己的 `<Claude 的家>/sessions/<pid>.json` 所在目录。hook 继承 Claude Code 的环境，`CLAUDE_CONFIG_DIR` 直接看得到。
    public var claudeSessions: URL

    public init(provider: String = "claude",
                directory: URL = HookRunner.defaultDirectory,
                now: @escaping () -> Date = Date.init,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                startPid: Int32 = getppid(),
                claudeSessions: URL = SessionRecord.claudeSessionsDirectory(configDir: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"])) {
        self.provider = HookRunner.providers.contains(provider) ? provider : "claude"
        self.directory = directory
        self.now = now
        self.environment = environment
        self.startPid = startPid
        self.claudeSessions = claudeSessions
    }
}

public enum HookOutcome: Equatable {
    case ignored
    case none
    case written(URL)
    case deleted(URL)
}

public enum HookRunner {

    public static let providers: Set<String> = ["claude", "codex"]

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Tally/sessions")
    }

    /// session_id 会拼进文件名，只放行安全字符，防路径穿越。
    public static func isValidSessionId(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-": return true
            default: return false
            }
        }
    }

    public static func run(input: [String: Any], options: HookOptions, table: ProcessTable) -> HookOutcome {
        guard let sessionId = input["session_id"] as? String, isValidSessionId(sessionId),
              let event = input["hook_event_name"] as? String, HookDecision.events.contains(event)
        else { return .ignored }

        // 设置页「最近收到事件」读它；写不进去不影响记状态，hook 本来也没有报错的出口
        try? HookHeartbeat(event: event, at: (options.now().timeIntervalSince1970 * 1000).rounded(),
                           claudeConfigDir: options.provider == "claude" ? options.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 } : nil)
            .write(sessionsDirectory: options.directory, provider: options.provider)

        let file = options.directory.appendingPathComponent("\(sessionId).json")
        let (existing, previous) = readExisting(file)
        let transcriptPath = input["transcript_path"] as? String ?? ""
        let turnEnded = {
            if !transcriptPath.isEmpty, TranscriptTitle.turnEnd(in: URL(fileURLWithPath: transcriptPath), provider: options.provider) != nil { return true }
            // idle_prompt 只在回合结束后一分钟发：Claude Code 自己说 idle，就是打断或报错没发 Stop（打断标记常常还没进 transcript）。
            // elicitation 是回合中途等人，不看 status。
            return input["notification_type"] as? String == "idle_prompt"
                && previous?.claudeCodeReportsIdle(in: options.claudeSessions) == true
        }
        let interactive = {
            !transcriptPath.isEmpty && TranscriptTitle.isInteractive(transcript: URL(fileURLWithPath: transcriptPath), provider: options.provider)
        }
        switch HookDecision.decide(event: event, input: input, existing: existing, turnEnded: turnEnded, interactive: interactive) {
        case .none:
            return .none
        case .delete:
            try? FileManager.default.removeItem(at: file)
            return .deleted(file)
        case .write(let state, let message):
            let agent = AgentLocator.find(startingAt: options.startPid, in: table)
            // cwd 只记第一次看到的：hook 收到的 cwd 会跟着会话里的 cd 走，定位窗口要的是 shell 所在目录。
            let cwd = (previous?.cwd).flatMap { $0.isEmpty ? nil : $0 }
                ?? (input["cwd"] as? String)
                ?? FileManager.default.currentDirectoryPath
            let title = transcriptPath.isEmpty
                ? nil
                : TranscriptTitle.read(from: URL(fileURLWithPath: transcriptPath), sessionId: sessionId)
            // 模型：入参带就用（Codex 带；它的 rollout 动辄几百 MB，一轮很长时尾巴里找不到 turn_context），
            // 没有就从 transcript 尾巴取（Claude），再没有沿用旧值——等输入之类的事件不该把已知的模型抹掉
            let model = (input["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (transcriptPath.isEmpty ? nil : TranscriptTitle.latestModel(in: URL(fileURLWithPath: transcriptPath)))
                ?? previous?.model
            let record = SessionRecord(
                sessionId: sessionId,
                provider: options.provider,
                pid: agent.map { Int($0.pid) },
                term: options.environment["TERM_PROGRAM"].flatMap { $0.isEmpty ? nil : $0 },
                tty: agent?.tty,
                state: state,
                cwd: cwd,
                title: title,
                transcriptPath: transcriptPath,
                message: message,
                updatedAt: (options.now().timeIntervalSince1970 * 1000).rounded(),
                model: model
            )
            do {
                try writeAtomic(record, to: file)
                return .written(file)
            } catch {
                return .none
            }
        }
    }

    /// 文件不存在 → missing；存在但不是合法记录 → unreadable，否则带上旧记录（cwd 要沿用）。
    static func readExisting(_ file: URL) -> (HookDecision.Existing, SessionRecord?) {
        guard FileManager.default.fileExists(atPath: file.path) else { return (.missing, nil) }
        guard let data = try? Data(contentsOf: file) else { return (.unreadable, nil) }
        if let record = try? JSONDecoder().decode(SessionRecord.self, from: data) {
            return (.state(record.state.rawValue), record)
        }
        // 老格式或手写的文件：只要有 state 字段就认状态，cwd 也尽量沿用
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let state = object["state"] as? String {
            let cwd = object["cwd"] as? String ?? ""
            let stub = SessionRecord(sessionId: "", state: .running, cwd: cwd, title: nil, transcriptPath: "", message: nil, updatedAt: 0)
            return (.state(state), cwd.isEmpty ? nil : stub)
        }
        return (.unreadable, nil)
    }

    static func writeAtomic(_ record: SessionRecord, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(record)
        let tmp = file.appendingPathExtension("tmp")
        try data.write(to: tmp)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }
}
