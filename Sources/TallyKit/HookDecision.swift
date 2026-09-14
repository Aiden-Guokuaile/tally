import Foundation

/// hook 的决策表：事件 + 现有状态 → 动作。纯函数，和 docs/ai.md 的映射表一一对应。
public enum HookDecision {

    /// 会注册的七种事件；不在这里的一律忽略。
    public static let events: Set<String> = [
        "SessionStart", "UserPromptSubmit", "Notification", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd",
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
    public static func decide(event: String, input: [String: Any], existing: Existing, turnEnded: () -> Bool = { false }) -> Action {
        switch event {
        case "SessionStart", "UserPromptSubmit":
            return .write(state: .running, message: nil)
        case "Stop":
            return .write(state: .done, message: clip(input["last_assistant_message"] as? String))
        case "SessionEnd":
            return .delete
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
