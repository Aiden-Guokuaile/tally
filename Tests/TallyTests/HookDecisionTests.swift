import XCTest
@testable import TallyKit

/// docs/ai.md 的映射表 12 行，各一个用例。
final class HookDecisionTests: XCTestCase {

    private func decide(_ event: String, _ input: [String: Any] = [:], existing: HookDecision.Existing = .missing) -> HookDecision.Action {
        HookDecision.decide(event: event, input: input, existing: existing)
    }

    func testSessionStartAndUserPromptSubmitWriteRunning() {
        XCTAssertEqual(decide("SessionStart", ["start_reason": "compact"]), .write(state: .running, message: nil))
        XCTAssertEqual(decide("UserPromptSubmit", existing: .state("done")), .write(state: .running, message: nil))
    }

    func testPermissionPromptNotificationWritesWaitingPermissionRegardlessOfExisting() {
        XCTAssertEqual(decide("Notification", ["notification_type": "permission_prompt"], existing: .missing), .write(state: .waitingPermission, message: nil))
        XCTAssertEqual(decide("Notification", ["notification_type": "permission_prompt"], existing: .state("done")), .write(state: .waitingPermission, message: nil))
    }

    func testIdleNotificationsWriteWaitingInputOnlyFromRunning() {
        for type in ["idle_prompt", "elicitation_dialog", "elicitation_url_dialog"] {
            XCTAssertEqual(decide("Notification", ["notification_type": type], existing: .state("running")), .write(state: .waitingInput, message: nil), type)
            XCTAssertEqual(decide("Notification", ["notification_type": type], existing: .state("done")), .none, type)
            XCTAssertEqual(decide("Notification", ["notification_type": type], existing: .missing), .none, type)
            XCTAssertEqual(decide("Notification", ["notification_type": type], existing: .unreadable), .none, type)
        }
    }

    func testIdleNotificationsDoNotWriteWhenTurnAlreadyEnded() {
        // 打断 / API 报错结束的回合不发 Stop，文件还停在 running
        for type in ["idle_prompt", "elicitation_dialog", "elicitation_url_dialog"] {
            XCTAssertEqual(HookDecision.decide(event: "Notification", input: ["notification_type": type], existing: .state("running"), turnEnded: { true }), .none, type)
        }
        var probed = false
        _ = HookDecision.decide(event: "Stop", input: [:], existing: .state("running"), turnEnded: { probed = true; return true })
        _ = HookDecision.decide(event: "Notification", input: ["notification_type": "idle_prompt"], existing: .state("done"), turnEnded: { probed = true; return true })
        XCTAssertFalse(probed, "只有 running 上的等输入通知才读 transcript")
    }

    func testOtherNotificationTypesAreIgnored() {
        for type in ["auth_success", "agent_completed", "quota_auto_resume_fired", "elicitation_complete", ""] {
            XCTAssertEqual(decide("Notification", ["notification_type": type], existing: .state("running")), .none, type)
        }
    }

    func testPermissionRequestWritesWaitingPermission() {
        XCTAssertEqual(decide("PermissionRequest", ["tool_name": "Bash"]), .write(state: .waitingPermission, message: nil))
    }

    func testPostToolUseCreatesRunningWhenFileMissing() {
        XCTAssertEqual(decide("PostToolUse", existing: .missing), .write(state: .running, message: nil))
    }

    func testPostToolUseFlipsWaitingPermissionBackToRunning() {
        XCTAssertEqual(decide("PostToolUse", existing: .state("waiting_permission")), .write(state: .running, message: nil))
    }

    func testPostToolUseRevivesDoneAndWaitingInput() {
        // 后台命令或子 agent 回来触发的新回合没有 UserPromptSubmit，靠工具调用把 done 改回 running
        XCTAssertEqual(decide("PostToolUse", existing: .state("done")), .write(state: .running, message: nil))
        XCTAssertEqual(decide("PostToolUse", existing: .state("waiting_input")), .write(state: .running, message: nil))
        XCTAssertEqual(decide("PostToolUse", existing: .unreadable), .write(state: .running, message: nil), "坏文件照样覆盖")
    }

    func testSubagentPostToolUseOnlyClearsApprovalWait() {
        let sub: [String: Any] = ["agent_id": "a1", "agent_type": "debugger"]
        XCTAssertEqual(decide("PostToolUse", sub, existing: .state("done")), .none, "主回合结束后子 agent 在后台干活不算又忙起来")
        XCTAssertEqual(decide("PostToolUse", sub, existing: .state("waiting_input")), .none)
        XCTAssertEqual(decide("PostToolUse", sub, existing: .state("ended")), .none)
        XCTAssertEqual(decide("PostToolUse", sub, existing: .state("compacting")), .none)
        XCTAssertEqual(decide("PostToolUse", sub, existing: .state("waiting_permission")), .write(state: .running, message: nil), "审批过了")
        XCTAssertEqual(decide("PostToolUse", sub, existing: .missing), .write(state: .running, message: nil), "Tally 装上时正跑着")
        XCTAssertEqual(decide("PostToolUse", ["agent_id": ""], existing: .state("done")), .write(state: .running, message: nil), "空的 agent_id 按主线程算")
    }

    func testPostToolUseIsNoopWhenAlreadyRunning() {
        XCTAssertEqual(decide("PostToolUse", existing: .state("running")), .none)
    }

    func testStopWritesDoneWithClippedMessage() {
        let long = String(repeating: "好", count: 130) + "😀"
        guard case .write(let state, let message) = decide("Stop", ["last_assistant_message": long]) else { return XCTFail() }
        XCTAssertEqual(state, .done)
        XCTAssertEqual(message?.unicodeScalars.count, 120)
        XCTAssertEqual(decide("Stop"), .write(state: .done, message: nil))
    }

    func testSessionEndKeepsInteractiveSessionsAsEndedAndDeletesOthers() {
        XCTAssertEqual(decide("SessionEnd"), .delete, "claude -p / codex exec 不留")
        XCTAssertEqual(HookDecision.decide(event: "SessionEnd", input: [:], existing: .state("done"), interactive: { true }), .write(state: .ended, message: nil))
        var probed = false
        _ = HookDecision.decide(event: "Stop", input: [:], existing: .state("running"), interactive: { probed = true; return true })
        XCTAssertFalse(probed, "只有 SessionEnd 才读 transcript 判交互")
    }

    func testPreCompactWritesCompacting() {
        XCTAssertEqual(decide("PreCompact", ["trigger": "auto"], existing: .state("running")), .write(state: .compacting, message: nil))
        XCTAssertEqual(decide("PreCompact", ["trigger": "manual"], existing: .state("done")), .write(state: .compacting, message: nil), "手动 /compact 时会话本来是 done")
    }

    func testUnknownEventIsNoop() {
        XCTAssertEqual(decide("PreToolUse"), .none)
        XCTAssertFalse(HookDecision.events.contains("PreToolUse"))
    }

    func testClipHandlesEmptyAndShort() {
        XCTAssertNil(HookDecision.clip(nil))
        XCTAssertNil(HookDecision.clip(""))
        XCTAssertEqual(HookDecision.clip("short"), "short")
    }
}
