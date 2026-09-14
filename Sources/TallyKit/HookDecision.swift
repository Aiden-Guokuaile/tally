import Foundation

/// hook 的决策表：事件 + 现有状态 → 动作。纯函数，和 docs/ai.md 的映射表一一对应。
public enum HookDecision {

    /// 两侧合起来会注册的事件；不在这里的一律忽略。
    public static let events: Set<String> = [
        "SessionStart", "UserPromptSubmit", "Notification", "PermissionRequest", "PostToolUse", "PreCompact", "Stop", "SessionEnd",
    ]

    /// Claude Code 里「等用户输入」的三种通知。
    public static let waitInputTypes: Set<String> = ["idle_prompt", "elicitation_dialog", "elicitation_url_dialog"]

    public static let messageCodepoints = 120

    /// 现有状态文件的情况。文件不存在和存在但解析不了要分开：需要看现有状态的行遇到坏文件按「不写」。
    public enum Existing: Equatable {
        case missing
        case unreadable
        case state(String)
    }

    public enum Action: Equatable {
        case write(state: SessionRecord.State, message: String?)
        case delete
        case none
    }

    /// `turnEnded`：回合其实已经结束（打断 / API 报错，两者都不发 Stop），依据见 `HookRunner`。
    /// 只有等输入那一行会调，读文件的开销不摊到别的事件上。
    /// `interactive`：是终端里开的交互会话（`TranscriptTitle.isInteractive`），只有 SessionEnd 那一行会调。
    public static func decide(event: String, input: [String: Any], existing: Existing,
                              turnEnded: () -> Bool = { false }, interactive: () -> Bool = { false }) -> Action {
        switch event {
        case "SessionStart", "UserPromptSubmit":
            return .write(state: .running, message: nil)
        case "Stop":
            return .write(state: .done, message: clip(input["last_assistant_message"] as? String))
        case "PreCompact":
            return .write(state: .compacting, message: nil)
        case "SessionEnd":
            // 交互会话留一行「已关闭」给人接着聊；claude -p / codex exec 这种脚本里跑的，留着只会越攒越多
            return interactive() ? .write(state: .ended, message: nil) : .delete
        case "PermissionRequest":
            return .write(state: .waitingPermission, message: nil)
        case "Notification":
            let type = input["notification_type"] as? String ?? ""
            if type == "permission_prompt" { return .write(state: .waitingPermission, message: nil) }
            if waitInputTypes.contains(type) {
                // done 之后闲置不算「等我」；打断 / API 报错结束的回合文件还停在 running，一样按 done 算
                return existing == .state("running") && !turnEnded() ? .write(state: .waitingInput, message: nil) : .none
            }
            return .none
        case "PostToolUse":
            // 后台子 agent 的工具调用也用主会话的 session_id 进来，带 agent_id（主线程永远不带）。主回合结束后它们照样在干活，
            // 不能把 done / 等输入翻回 running（不然 60 秒后 idle_prompt 还会写成等输入）；只放行审批过了和还没有文件的情况
            if let agent = input["agent_id"] as? String, !agent.isEmpty {
                switch existing {
                case .missing, .unreadable, .state("waiting_permission"): return .write(state: .running, message: nil)
                default: return .none
                }
            }
            // 工具跑完就是 agent 在干活：文件不存在（Tally 装上时会话正在长回合中间）、done（后台命令或子 agent
            // 回来触发的新回合没有 UserPromptSubmit）、等审批（审批必然已过）都要改回 running；已经 running 就不写，省得每次工具调用都改文件。
            return existing == .state("running") ? .none : .write(state: .running, message: nil)
        default:
            return .none
        }
    }

    /// Stop 的 last_assistant_message 取前 120 个 Unicode 码点。
    public static func clip(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return String(String.UnicodeScalarView(text.unicodeScalars.prefix(messageCodepoints)))
    }
}
