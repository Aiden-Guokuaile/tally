import XCTest
@testable import TallyKit

/// 假进程表：给定一条父链，可选每个 pid 的 argv。
private struct FakeTable: ProcessTable {
    let rows: [ProcessEntry]
    var args: [Int32: [String]] = [:]
    func entries() -> [ProcessEntry] { rows }
    func arguments(of pid: Int32) -> [String] { args[pid] ?? [] }
}

/// node 版 hooks/claude-event.test.js 的用例逐条改写，加上 pid / tty / term。
final class HookRunnerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        // 多套一层 sessions：hook 的心跳写在会话目录上一层，每个用例得有自己的上一层
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tally-hook-\(UUID().uuidString)").appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // 祖先链：hook(100) ← sh(90) ← claude(80, tty 设备号 5) ← zsh(70)
    private let chain = [
        ProcessEntry(pid: 100, ppid: 90, comm: "node", tdev: nil),
        ProcessEntry(pid: 90, ppid: 80, comm: "sh", tdev: nil),
        ProcessEntry(pid: 80, ppid: 70, comm: "claude", tdev: 5),
        ProcessEntry(pid: 70, ppid: 1, comm: "zsh", tdev: 5),
    ]

    private func options(provider: String = "claude", now: Date = Date(timeIntervalSince1970: 42), term: String? = "ghostty", startPid: Int32 = 100) -> HookOptions {
        var environment: [String: String] = [:]
        if let term { environment["TERM_PROGRAM"] = term }
        return HookOptions(provider: provider, directory: directory, now: { now }, environment: environment, startPid: startPid)
    }

    private func event(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
        var input: [String: Any] = ["session_id": "abc-123", "hook_event_name": name, "cwd": "/tmp/x", "transcript_path": ""]
        extra.forEach { input[$0] = $1 }
        return input
    }

    private func run(_ input: [String: Any], options: HookOptions? = nil, table: ProcessTable? = nil) -> HookOutcome {
        HookRunner.run(input: input, options: options ?? self.options(), table: table ?? FakeTable(rows: chain))
    }

    private func read(_ id: String = "abc-123") throws -> SessionRecord {
        try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: directory.appendingPathComponent("\(id).json")))
    }

    private func writeState(_ id: String, _ state: String) throws {
        try Data("{\"session_id\":\"\(id)\",\"state\":\"\(state)\",\"cwd\":\"/tmp/x\",\"updated_at\":1}".utf8)
            .write(to: directory.appendingPathComponent("\(id).json"))
    }

    private func rawJSON(_ id: String = "abc-123") throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("\(id).json"))) as? [String: Any])
    }

    // ── 映射表 ────────────────────────────────────────────────

    func testSessionStartWritesFullRecordWithPidTtyTerm() throws {
        guard case .written = run(event("SessionStart", ["start_reason": "compact"])) else { return XCTFail() }
        let r = try read()
        XCTAssertEqual(r.state, .running)
        XCTAssertEqual(r.provider, "claude")
        XCTAssertEqual(r.pid, 80)
        XCTAssertEqual(r.term, "ghostty")
        XCTAssertEqual(r.cwd, "/tmp/x")
        XCTAssertNil(r.title)
        XCTAssertNil(r.message)
        XCTAssertEqual(r.updatedAt, 42_000)
        // tty 由 devname 转，测试环境里设备号 5 不一定存在，只断言键存在且 pid 对
        let json = try rawJSON()
        XCTAssertTrue(json.keys.contains("tty"))
        XCTAssertTrue(json.keys.contains("term"))
    }

    func testNullKeysAreWrittenExplicitly() throws {
        _ = run(event("SessionStart"), options: options(term: nil), table: FakeTable(rows: []))
        let json = try rawJSON()
        XCTAssertTrue(json["pid"] is NSNull)
        XCTAssertTrue(json["tty"] is NSNull)
        XCTAssertTrue(json["term"] is NSNull)
        XCTAssertTrue(json["title"] is NSNull)
        XCTAssertTrue(json["message"] is NSNull)
        XCTAssertTrue(json["model"] is NSNull, "模型还不知道也要写出键")
    }

    func testUserPromptSubmitWritesRunning() throws {
        _ = run(event("UserPromptSubmit"))
        XCTAssertEqual(try read().state, .running)
    }

    func testPermissionPromptAndPermissionRequestWriteWaitingPermission() throws {
        _ = run(event("Notification", ["notification_type": "permission_prompt"]))
        XCTAssertEqual(try read().state, .waitingPermission)
        _ = run(event("PermissionRequest", ["tool_name": "Bash"]), options: options(provider: "codex"))
        let r = try read()
        XCTAssertEqual(r.state, .waitingPermission)
        XCTAssertEqual(r.provider, "codex")
    }

    func testIdleNotificationOnlyFromRunning() throws {
        for type in ["idle_prompt", "elicitation_dialog", "elicitation_url_dialog"] {
            try writeState("abc-123", "running")
            _ = run(event("Notification", ["notification_type": type]))
            XCTAssertEqual(try read().state, .waitingInput, type)
        }
        try writeState("abc-123", "done")
        XCTAssertEqual(run(event("Notification", ["notification_type": "idle_prompt"])), .none)
        XCTAssertEqual(try read().state, .done)
    }

    func testIdleNotificationAfterInterruptOrApiErrorDoesNotWriteWaitingInput() throws {
        // 打断和 API 报错结束的回合不发 Stop，文件停在 running；一分钟后的 idle_prompt 不能把它当「等输入」
        let prompt = #"{"type":"user","message":{"role":"user","content":"跑一下"}}"#
        let endings = [
            "interrupt": #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#,
            "api error": #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"API Error: Rate limit reached"}]}}"#,
        ]
        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("tally-transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        for (name, ending) in endings {
            let snapshot = #"{"type":"file-history-snapshot","snapshot":{}}"#
            try ([prompt, ending, snapshot].joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
            try writeState("abc-123", "running")
            XCTAssertEqual(run(event("Notification", ["notification_type": "idle_prompt", "transcript_path": transcript.path])), .none, name)
            XCTAssertEqual(try read().state, .running, name)
        }
    }

    func testIdlePromptDoesNotWriteWhenClaudeCodeReportsIdleButElicitationStillDoes() throws {
        // 还没开始输出就按 Esc：打断标记还没进 transcript，只有 Claude Code 自己的 status 是 idle
        let claudeSessions = FileManager.default.temporaryDirectory.appendingPathComponent("tally-cc-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: claudeSessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: claudeSessions) }
        try Data(#"{"pid":4242,"sessionId":"abc-123","status":"idle"}"#.utf8).write(to: claudeSessions.appendingPathComponent("4242.json"))
        var opts = options()
        opts.claudeSessions = claudeSessions
        let running = Data(#"{"session_id":"abc-123","pid":4242,"state":"running","cwd":"/tmp/x","updated_at":1}"#.utf8)

        try running.write(to: directory.appendingPathComponent("abc-123.json"))
        XCTAssertEqual(run(event("Notification", ["notification_type": "idle_prompt"]), options: opts), .none)
        XCTAssertEqual(try read().state, .running)

        // elicitation 是回合中途等人，不看 status，照常写等输入
        guard case .written = run(event("Notification", ["notification_type": "elicitation_dialog"]), options: opts) else { return XCTFail() }
        XCTAssertEqual(try read().state, .waitingInput)

        // status 对不上这个会话（pid 被复用）：idle_prompt 照常写等输入
        try Data(#"{"pid":4242,"sessionId":"someone-else","status":"idle"}"#.utf8).write(to: claudeSessions.appendingPathComponent("4242.json"))
        try running.write(to: directory.appendingPathComponent("abc-123.json"))
        guard case .written = run(event("Notification", ["notification_type": "idle_prompt"]), options: opts) else { return XCTFail() }
        XCTAssertEqual(try read().state, .waitingInput)
    }

    func testOtherNotificationTypesDoNotTouchFiles() throws {
        for type in ["auth_success", "agent_completed", "quota_auto_resume_fired", "elicitation_complete"] {
            XCTAssertEqual(run(event("Notification", ["notification_type": type])), .none, type)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testPostToolUseFlipsBackAndCreatesWhenMissing() throws {
        try writeState("abc-123", "waiting_permission")
        guard case .written = run(event("PostToolUse")) else { return XCTFail() }
        XCTAssertEqual(try read().state, .running)
        XCTAssertEqual(run(event("PostToolUse")), .none, "已经 running 不重写")
        try writeState("abc-123", "done")
        guard case .written = run(event("PostToolUse")) else { return XCTFail("done 之后又有工具调用，是后台命令或子 agent 回来的新回合") }
        XCTAssertEqual(try read().state, .running)

        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("tally-hook-\(UUID().uuidString)")
        var opts = options()
        opts.directory = fresh
        guard case .written = HookRunner.run(input: event("PostToolUse"), options: opts, table: FakeTable(rows: chain)) else { return XCTFail() }
        let r = try JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: fresh.appendingPathComponent("abc-123.json")))
        XCTAssertEqual(r.state, .running)
    }

    func testStopWritesDoneWithClippedMessage() throws {
        let long = String(repeating: "好", count: 130) + "😀"
        _ = run(event("Stop", ["last_assistant_message": long]))
        let r = try read()
        XCTAssertEqual(r.state, .done)
        XCTAssertEqual(r.message?.unicodeScalars.count, 120)
    }

    func testSubagentToolCallsDoNotReviveFinishedTurn() throws {
        // 实测的顺序：主回合 Stop，1 秒后后台子 agent 的工具调用带着同一个 session_id 进来，60 秒后 idle_prompt
        _ = run(event("Stop", ["last_assistant_message": "好了"]))
        XCTAssertEqual(run(event("PostToolUse", ["agent_id": "a1", "agent_type": "debugger"])), .none)
        XCTAssertEqual(run(event("Notification", ["notification_type": "idle_prompt"])), .none)
        XCTAssertEqual(try read().state, .done)
    }

    func testAcceptedEventsLeaveAHeartbeatNextToTheSessionsDirectory() throws {
        _ = run(event("UserPromptSubmit"), options: options(now: Date(timeIntervalSince1970: 7)))
        XCTAssertEqual(HookHeartbeat.read(sessionsDirectory: directory, provider: "claude"), HookHeartbeat(event: "UserPromptSubmit", at: 7000))
        XCTAssertEqual(run(["hook_event_name": "Stop"]), .ignored)
        XCTAssertEqual(HookHeartbeat.read(sessionsDirectory: directory, provider: "claude")?.event, "UserPromptSubmit", "校验不过不写")

        // Claude 侧顺带记下 Claude Code 进程里的 CLAUDE_CONFIG_DIR，app 问不到 .zshrc 里的变量时靠它
        var withConfigDir = options(now: Date(timeIntervalSince1970: 8))
        withConfigDir.environment["CLAUDE_CONFIG_DIR"] = "/Users/x/.claude-work"
        _ = run(event("Stop"), options: withConfigDir)
        XCTAssertEqual(HookHeartbeat.read(sessionsDirectory: directory, provider: "claude")?.claudeConfigDir, "/Users/x/.claude-work")
        _ = run(event("Stop"), options: options(provider: "codex", now: Date(timeIntervalSince1970: 9)))
        XCTAssertNil(HookHeartbeat.read(sessionsDirectory: directory, provider: "codex")?.claudeConfigDir, "Codex 侧不记")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("hook-last") }, "不写在被 kqueue 盯着的会话目录里")
    }

    func testSessionEndDeletesNonInteractiveAndIsIdempotent() throws {
        try writeState("abc-123", "done")
        guard case .deleted = run(event("SessionEnd")) else { return XCTFail() }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        guard case .deleted = run(event("SessionEnd")) else { return XCTFail("不存在也算删成功") }
    }

    func testSessionEndKeepsInteractiveSessionAsEnded() throws {
        let transcript = FileManager.default.temporaryDirectory.appendingPathComponent("tally-cli-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: transcript) }
        try (#"{"type":"user","entrypoint":"cli","message":{"role":"user","content":"跑一下"}}"# + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        try writeState("abc-123", "done")
        guard case .written = run(event("SessionEnd", ["transcript_path": transcript.path])) else { return XCTFail() }
        XCTAssertEqual(try read().state, .ended)

        try (#"{"type":"user","entrypoint":"sdk-cli","message":{"role":"user","content":"跑一下"}}"# + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        guard case .deleted = run(event("SessionEnd", ["transcript_path": transcript.path])) else { return XCTFail("claude -p 不留") }
    }

    // ── 守门 ────────────────────────────────────────────────────

    func testMissingOrInvalidSessionIdAndUnknownEventAreIgnored() throws {
        XCTAssertEqual(run(["hook_event_name": "Stop"]), .ignored)
        XCTAssertEqual(run(["session_id": "../evil", "hook_event_name": "Stop"]), .ignored)
        XCTAssertEqual(run(event("PreToolUse")), .ignored)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testUnreadableExistingFileBlocksConditionalRowsButNotUnconditional() throws {
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("abc-123.json"))
        XCTAssertEqual(run(event("Notification", ["notification_type": "idle_prompt"])), .none, "要看现有状态的行遇到坏文件不写")
        guard case .written = run(event("PostToolUse")) else { return XCTFail("PostToolUse 不看现有状态，坏文件照样覆盖") }
        XCTAssertEqual(try read().state, .running)
        try Data("{not json".utf8).write(to: directory.appendingPathComponent("abc-123.json"))
        guard case .written = run(event("UserPromptSubmit")) else { return XCTFail() }
        XCTAssertEqual(try read().state, .running)
    }

    func testUnknownProviderFallsBackToClaude() throws {
        _ = run(event("SessionStart"), options: options(provider: "gemini"))
        XCTAssertEqual(try read().provider, "claude")
    }

    func testCwdIsKeptFromFirstRecord() throws {
        _ = run(event("SessionStart", ["cwd": "/Users/me/workspace/MacAppProject"]))
        _ = run(event("Stop", ["cwd": "/Users/me/workspace/MacAppProject/tally", "last_assistant_message": "x"]))
        let r = try read()
        XCTAssertEqual(r.state, .done)
        XCTAssertEqual(r.cwd, "/Users/me/workspace/MacAppProject")
    }

    // ── pid / tty ──────────────────────────────────────────────

    func testAgentLocatorWalksUpToClaudeOrCodex() {
        let found = AgentLocator.find(startingAt: 100, in: FakeTable(rows: chain))
        XCTAssertEqual(found?.pid, 80)
        let codex = [ProcessEntry(pid: 5, ppid: 4, comm: "sh", tdev: nil), ProcessEntry(pid: 4, ppid: 1, comm: "codex", tdev: nil)]
        XCTAssertEqual(AgentLocator.find(startingAt: 5, in: FakeTable(rows: codex))?.pid, 4)
        XCTAssertNil(AgentLocator.find(startingAt: 5, in: FakeTable(rows: codex))?.tty, "NODEV 时 tty 为 nil")
    }

    func testAgentLocatorRecognizesVersionNamedBinaryAndInterpreterRuns() {
        // 官方安装器：~/.local/bin/claude → ~/.local/share/claude/versions/2.1.263，短名是版本号
        let versioned = [
            ProcessEntry(pid: 9, ppid: 8, comm: "zsh", path: "/bin/zsh", tdev: nil),
            ProcessEntry(pid: 8, ppid: 1, comm: "2.1.263", path: "/Users/me/.local/share/claude/versions/2.1.263", tdev: 7),
        ]
        XCTAssertEqual(AgentLocator.find(startingAt: 9, in: FakeTable(rows: versioned))?.pid, 8)
        // npm 装的：node 跑 cli.js
        let node = [
            ProcessEntry(pid: 9, ppid: 8, comm: "sh", path: "/bin/sh", tdev: nil),
            ProcessEntry(pid: 8, ppid: 1, comm: "node", path: "/opt/homebrew/bin/node", tdev: nil),
        ]
        let table = FakeTable(rows: node, args: [8: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]])
        XCTAssertEqual(AgentLocator.find(startingAt: 9, in: table)?.pid, 8)
        // 普通 node 进程不算
        let plainNode = FakeTable(rows: node, args: [8: ["node", "server.js"]])
        XCTAssertNil(AgentLocator.find(startingAt: 9, in: plainNode))
    }

    func testAgentLocatorReturnsNilWithoutAgentAncestor() {
        let rows = [ProcessEntry(pid: 100, ppid: 90, comm: "node", tdev: nil), ProcessEntry(pid: 90, ppid: 1, comm: "launchd", tdev: nil)]
        XCTAssertNil(AgentLocator.find(startingAt: 100, in: FakeTable(rows: rows)))
        _ = run(event("SessionStart"), table: FakeTable(rows: rows))
        let r = try? read()
        XCTAssertNil(r?.pid)
        XCTAssertNil(r?.tty)
    }

    func testRealProcessTableContainsSelf() {
        let me = SysctlProcessTable().entries().first { $0.pid == ProcessInfo.processInfo.processIdentifier }
        XCTAssertNotNil(me)
        XCTAssertEqual(me?.ppid, getppid())
    }

    // ── 标题 ────────────────────────────────────────────────────

    func testTitleReadFromTranscriptTailAndSidecar() throws {
        let transcript = directory.appendingPathComponent("t.jsonl")
        try "{\"type\":\"ai-title\",\"aiTitle\":\"自动标题\",\"sessionId\":\"abc-123\"}\n".write(to: transcript, atomically: true, encoding: .utf8)
        _ = run(event("SessionStart", ["transcript_path": transcript.path]))
        XCTAssertEqual(try read().title, "自动标题")

        let sidecarDir = directory.appendingPathComponent("abc-123")
        try FileManager.default.createDirectory(at: sidecarDir, withIntermediateDirectories: true)
        try "{\"customTitle\":\"边车标题\"}".write(to: sidecarDir.appendingPathComponent("custom-title.json"), atomically: true, encoding: .utf8)
        _ = run(event("UserPromptSubmit", ["transcript_path": transcript.path]))
        XCTAssertEqual(try read().title, "边车标题")
    }

    // ── 模型 ────────────────────────────────────────────────────

    func testModelFromHookInputWinsAndSurvivesEventsWithoutIt() throws {
        // Codex 的入参带 model
        _ = run(event("UserPromptSubmit", ["model": "gpt-6-astra"]), options: options(provider: "codex"))
        XCTAssertEqual(try read().model, "gpt-6-astra")
        // 之后的事件没带、transcript 也没有：沿用，不抹掉
        _ = run(event("Stop", ["last_assistant_message": "好了"]), options: options(provider: "codex"))
        XCTAssertEqual(try read().model, "gpt-6-astra")
    }

    func testClaudeModelComesFromTranscriptTail() throws {
        let transcript = directory.appendingPathComponent("t.jsonl")
        let lines = [
            #"{"type":"assistant","message":{"id":"m1","model":"claude-opus-4-8","usage":{"output_tokens":1}}}"#,
            #"{"type":"assistant","message":{"id":"m2","model":"claude-opus-5","usage":{"output_tokens":1}}}"#,
            #"{"type":"assistant","message":{"id":"m3","model":"<synthetic>","content":"API Error"}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        _ = run(event("Stop", ["transcript_path": transcript.path]))
        XCTAssertEqual(try read().model, "claude-opus-5", "取最后一条真回复的模型，跳过报错时写的 <synthetic>")
    }

    func testCodexTurnContextInTailIsUnderstood() throws {
        let transcript = directory.appendingPathComponent("r.jsonl")
        try #"{"type":"turn_context","payload":{"model":"gpt-6-astra","cwd":"/tmp"}}"#.appending("\n").write(to: transcript, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptTitle.latestModel(in: transcript), "gpt-6-astra")
        XCTAssertNil(TranscriptTitle.latestModel(in: directory.appendingPathComponent("absent.jsonl")))
    }

    func testIsValidSessionId() {
        XCTAssertTrue(HookRunner.isValidSessionId("01a08063-7d98-7a60-9279-a2aaae8cd531"))
        XCTAssertFalse(HookRunner.isValidSessionId(""))
        XCTAssertFalse(HookRunner.isValidSessionId("a/b"))
        XCTAssertFalse(HookRunner.isValidSessionId("a b"))
    }
}
