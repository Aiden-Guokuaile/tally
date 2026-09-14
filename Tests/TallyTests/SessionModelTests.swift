import XCTest
@testable import Tally

final class SessionModelTests: XCTestCase {

    private func record(state: SessionRecord.State, ageSeconds: Double, now: Date, title: String? = "标题") -> SessionRecord {
        SessionRecord(
            sessionId: "s1",
            state: state,
            cwd: "/Users/me/workspace/MacAppProject",
            title: title,
            transcriptPath: "",
            message: nil,
            updatedAt: now.addingTimeInterval(-ageSeconds).timeIntervalSince1970 * 1000
        )
    }

    func testDecodesHookJSON() throws {
        let json = """
        {"session_id":"abc","provider":"codex","pid":4242,"state":"waiting_permission","cwd":"/tmp/x","title":null,"transcript_path":"/t.jsonl","message":null,"updated_at":1700000000000}
        """
        let r = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        XCTAssertEqual(r.sessionId, "abc")
        XCTAssertEqual(r.provider, "codex")
        XCTAssertEqual(r.providerLabel, "Codex")
        XCTAssertEqual(r.pid, 4242)
        XCTAssertEqual(r.state, .waitingPermission)
        XCTAssertNil(r.title)
        XCTAssertEqual(r.updatedDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(r.isWaiting)
    }

    func testModelShortNames() {
        XCTAssertEqual(SessionRecord.shortModelName("claude-opus-5"), "Opus 5")
        XCTAssertEqual(SessionRecord.shortModelName("claude-opus-4-8"), "Opus 4.8")
        XCTAssertEqual(SessionRecord.shortModelName("claude-fable-5-1"), "Fable 5.1")
        XCTAssertEqual(SessionRecord.shortModelName("claude-haiku-4-5-20251001"), "Haiku 4.5", "去掉日期戳")
        XCTAssertEqual(SessionRecord.shortModelName("claude-3-5-sonnet-20241022"), "Sonnet 3.5", "老式命名版本号在前")
        XCTAssertEqual(SessionRecord.shortModelName("gpt-6-astra"), "gpt-6-astra", "别家的原样用，不猜营销名")
        var r = record(state: .running, ageSeconds: 0, now: Date())
        XCTAssertNil(r.modelLabel, "还不知道模型")
        r.model = "claude-sonnet-5"
        XCTAssertEqual(r.modelLabel, "Sonnet 5")
    }

    func testOldJSONWithoutModelDecodes() throws {
        let json = #"{"session_id":"abc","provider":"codex","state":"done","cwd":"/tmp","updated_at":1}"#
        XCTAssertNil(try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8)).model)
    }

    func testOldJSONWithoutProviderIsClaude() throws {
        let json = #"{"session_id":"abc","state":"done","cwd":"/tmp","updated_at":1}"#
        let r = try JSONDecoder().decode(SessionRecord.self, from: Data(json.utf8))
        XCTAssertEqual(r.provider, "claude")
        XCTAssertTrue(r.isClaude)
        XCTAssertNil(r.pid)
        XCTAssertEqual(r.transcriptPath, "")
    }

    // 陈旧与清理表 3 行

    func testNonDoneOlderThanTwoHoursIsStale() {
        let now = Date()
        XCTAssertTrue(record(state: .waitingPermission, ageSeconds: 2 * 3600 + 1, now: now).isStale(now: now))
        XCTAssertFalse(record(state: .running, ageSeconds: 2 * 3600 - 1, now: now).isStale(now: now))
    }

    func testDoneNeverStale() {
        let now = Date()
        XCTAssertFalse(record(state: .done, ageSeconds: 3 * 3600, now: now).isStale(now: now))
    }

    func testOrphansOlderThan24Hours() {
        let now = Date()
        let old = URL(fileURLWithPath: "/tmp/old.json")
        let fresh = URL(fileURLWithPath: "/tmp/fresh.json")
        let result = SessionRecord.orphans(
            files: [(old, now.addingTimeInterval(-24 * 3600 - 1)), (fresh, now.addingTimeInterval(-23 * 3600))],
            now: now
        )
        XCTAssertEqual(result, [old])
    }

    // 存活

    func testProcessIsGoneUsesKillZero() {
        var alive = record(state: .running, ageSeconds: 0, now: Date())
        alive.pid = Int(ProcessInfo.processInfo.processIdentifier)
        XCTAssertFalse(alive.processIsGone)

        var dead = alive
        dead.pid = 999_999 // 超过 macOS 的 pid 上限，不可能存在
        XCTAssertTrue(dead.processIsGone)

        var unknown = alive
        unknown.pid = nil
        XCTAssertFalse(unknown.processIsGone)
    }

    // 徽标与显示

    func testWaitingCountExcludesStale() {
        let now = Date()
        XCTAssertTrue(record(state: .waitingInput, ageSeconds: 60, now: now).countsAsWaiting(now: now))
        XCTAssertFalse(record(state: .waitingInput, ageSeconds: 3 * 3600, now: now).countsAsWaiting(now: now))
        XCTAssertFalse(record(state: .running, ageSeconds: 60, now: now).countsAsWaiting(now: now))
    }

    func testDisplayTitleFallsBackToCwdLastComponent() {
        let now = Date()
        XCTAssertEqual(record(state: .running, ageSeconds: 0, now: now, title: nil).displayTitle, "MacAppProject")
        XCTAssertEqual(record(state: .running, ageSeconds: 0, now: now, title: "").displayTitle, "MacAppProject")
        var root = record(state: .running, ageSeconds: 0, now: now, title: nil)
        root.cwd = "/"
        XCTAssertEqual(root.cwdLabel, "/")
    }
}

final class SessionAlertTests: XCTestCase {

    private func record(_ id: String, _ state: SessionRecord.State) -> SessionRecord {
        SessionRecord(sessionId: id, state: state, cwd: "/tmp/x", title: "t", transcriptPath: "", message: nil, updatedAt: 1)
    }

    @MainActor
    func testRunningToDoneCounts() {
        let out = SessionStore.alerts(previous: [record("a", .running), record("b", .waitingInput)],
                                      current: [record("a", .done), record("b", .done)])
        XCTAssertEqual(out.map(\.sessionId), ["a", "b"])
    }

    @MainActor
    func testEnteringWaitingCounts() {
        XCTAssertEqual(SessionStore.alerts(previous: [record("a", .running)], current: [record("a", .waitingPermission)]).count, 1, "等审批要弹")
        XCTAssertEqual(SessionStore.alerts(previous: [record("a", .running)], current: [record("a", .waitingInput)]).count, 1, "等输入要弹")
        XCTAssertTrue(SessionStore.alerts(previous: [record("a", .waitingPermission)], current: [record("a", .running)]).isEmpty, "审批过了回到 running 不弹")
    }

    @MainActor
    func testFirstSeenAlreadyDoneDoesNotCount() {
        XCTAssertTrue(SessionStore.alerts(previous: [], current: [record("a", .done), record("b", .waitingPermission)]).isEmpty)
    }

    @MainActor
    func testSameStateDoesNotRepeat() {
        XCTAssertTrue(SessionStore.alerts(previous: [record("a", .done)], current: [record("a", .done)]).isEmpty)
        XCTAssertTrue(SessionStore.alerts(previous: [record("a", .waitingInput)], current: [record("a", .waitingInput)]).isEmpty)
    }

    @MainActor
    func testEveryTurnCounts() {
        // done → running → done：第二个回合结束也要提示
        XCTAssertTrue(SessionStore.alerts(previous: [record("a", .done)], current: [record("a", .running)]).isEmpty)
        XCTAssertEqual(SessionStore.alerts(previous: [record("a", .running)], current: [record("a", .done)]).count, 1)
    }

    @MainActor
    func testQuietSessionsDoNotCount() {
        let out = SessionStore.alerts(previous: [record("a", .running), record("b", .running)],
                                      current: [record("a", .done), record("b", .done)], quiet: ["a"])
        XCTAssertEqual(out.map(\.sessionId), ["b"], "打断补判出来的 done 不弹")
    }
}

/// 打断和 API 报错结束的回合不发 Stop：app 读 transcript 尾巴补判（docs/ai.md「打断与 API 报错」）。
final class SessionTurnEndTests: XCTestCase {

    private var directory: URL!
    private var transcript: URL!
    private var claudeSessions: URL!

    private let prompt = #"{"type":"user","message":{"role":"user","content":"跑一下"}}"#
    private let interrupt = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
    private let apiError = #"{"type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"You've hit your session limit · resets 3pm"}]}}"#
    private let snapshot = #"{"type":"file-history-snapshot","snapshot":{}}"#

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tally-turn-\(UUID().uuidString)")
        directory = root.appendingPathComponent("sessions")
        transcript = root.appendingPathComponent("t.jsonl")
        claudeSessions = root.appendingPathComponent("claude-sessions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSessions, withIntermediateDirectories: true)
    }

    /// 模拟 hook 写的状态文件 + 此刻的 transcript。
    private func write(state: SessionRecord.State, provider: String = "claude", transcript lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let record = SessionRecord(sessionId: "s1", provider: provider, pid: Int(ProcessInfo.processInfo.processIdentifier),
                                   state: state, cwd: "/tmp/x", title: "t", transcriptPath: transcript.path, message: nil, updatedAt: 1)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent("s1.json"))
    }

    /// 模拟 Claude Code 自己写的 `~/.claude/sessions/<pid>.json`；pid 用测试进程自己的，存活判定才过得去。
    private func writeClaudeStatus(_ status: String, sessionId: String = "s1") throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let json = #"{"pid":\#(pid),"sessionId":"\#(sessionId)","status":"\#(status)","statusUpdatedAt":1}"#
        try Data(json.utf8).write(to: claudeSessions.appendingPathComponent("\(pid).json"))
    }

    @MainActor
    private func makeStore() -> SessionStore {
        SessionStore(directory: directory, claudeSessions: claudeSessions)
    }

    @MainActor
    func testInterruptSettlesToDoneQuietlyAndNextPromptRunsAgain() throws {
        var alerts: [SessionRecord] = []
        let store = makeStore()
        store.sessionAlert = { alerts.append($0) }

        try write(state: .waitingPermission, transcript: [prompt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingPermission)

        // 在审批框上按 Esc：没有 Stop，文件还是等审批
        try write(state: .waitingPermission, transcript: [prompt, interrupt, snapshot])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertNil(store.sessions.first?.message)
        XCTAssertTrue(alerts.isEmpty, "人就在终端前按的键，不弹")

        // 下一句话：hook 写 running，尾巴最后一条是新输入
        try write(state: .running, transcript: [prompt, interrupt, snapshot, prompt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running)
        XCTAssertTrue(alerts.isEmpty)
    }

    @MainActor
    func testApiErrorSettlesToDoneAndAlertsWithTheError() throws {
        var alerts: [SessionRecord] = []
        let store = makeStore()
        store.sessionAlert = { alerts.append($0) }

        try write(state: .running, transcript: [prompt])
        store.reload()
        try write(state: .running, transcript: [prompt, apiError])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.message, "You've hit your session limit · resets 3pm")
    }

    @MainActor
    func testCodexAndDoneRecordsAreLeftAlone() throws {
        let store = makeStore()
        try write(state: .running, provider: "codex", transcript: [prompt, interrupt])
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running, "Codex 的 rollout 格式不同，不套这条规则")

        try write(state: .done, transcript: [prompt, apiError])
        store.reload()
        XCTAssertNil(store.sessions.first?.message, "已经是 done 的不读尾巴、不改 message")
    }

    @MainActor
    func testClaudeCodeIdleStatusSettlesInterruptWithoutMarkerQuietly() throws {
        // 还没开始输出就按 Esc：打断标记要等下一句话才写进 transcript，只有 Claude Code 自己的 status 变成 idle
        var alerts: [SessionRecord] = []
        let store = makeStore()
        store.sessionAlert = { alerts.append($0) }

        try write(state: .running, transcript: [prompt])
        try writeClaudeStatus("busy")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .running)

        try writeClaudeStatus("idle")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .done)
        XCTAssertTrue(alerts.isEmpty, "打断不弹")
    }

    @MainActor
    func testClaudeCodeStatusMustBeIdleAndBelongToTheSession() throws {
        let store = makeStore()
        try write(state: .waitingPermission, transcript: [prompt])
        try writeClaudeStatus("waiting")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingPermission, "等审批时 Claude Code 写的是 waiting")

        try writeClaudeStatus("idle", sessionId: "someone-else")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingPermission, "pid 被复用成了别的会话")

        try write(state: .waitingInput, transcript: [prompt])
        try writeClaudeStatus("idle")
        store.reload()
        XCTAssertEqual(store.sessions.first?.state, .waitingInput, "等输入（elicitation 对话框）不看 status")
    }
}
