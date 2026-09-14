import AppKit
import Foundation

/// 接着聊一个已关闭的会话：在新终端里 `cd` 到会话目录再 `claude --resume` / `codex resume`（docs/ai.md「已关闭的会话」）。
enum SessionResume {

    /// `claude --resume <id>` 默认沿用原来的 session_id，接上之后 hook 写回同一个文件，还是这一行。
    static func tool(for session: SessionRecord) -> String {
        session.provider == "codex" ? "codex resume" : "claude --resume"
    }

    static func command(for session: SessionRecord) -> String {
        "cd \(shellQuote(session.cwd)) && \(tool(for: session)) \(shellQuote(session.sessionId))"
    }

    /// 单引号包起来，内部的单引号写成 '\''。
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript 字符串字面量：反斜杠和双引号转义。
    static func appleScriptString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func ghosttyScript(_ command: String) -> String {
        """
        tell application id "com.mitchellh.ghostty"
            set cfg to new surface configuration
            set initial input of cfg to \(appleScriptString(command)) & linefeed
            new window with configuration cfg
            activate
        end tell
        """
    }

    static func terminalScript(_ command: String) -> String {
        """
        tell application id "com.apple.Terminal"
            do script \(appleScriptString(command))
            activate
        end tell
        """
    }

    static func itermScript(_ command: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
            set w to (create window with default profile)
            tell current session of w to write text \(appleScriptString(command))
            activate
        end tell
        """
    }

    @MainActor
    static func run(_ session: SessionRecord) async throws {
        let command = command(for: session)
        switch TerminalLocator.kind(for: session.term, running: TerminalLocator.isRunning) {
        case .terminalApp:
            _ = try await TerminalLocator.runAppleScript(terminalScript(command), target: "Terminal")
        case .iterm:
            _ = try await TerminalLocator.runAppleScript(itermScript(command), target: "iTerm")
        case .tmux:
            if try await inTmux(session) { return }
            try await inDefaultTerminal(command)
        case .ghostty:
            _ = try await TerminalLocator.runAppleScript(ghosttyScript(command), target: "Ghostty")
        case .editor, .activate, .unknown:
            try await inDefaultTerminal(command)
        }
    }

    /// 装了 Ghostty 用 Ghostty，否则 Terminal.app。
    @MainActor
    private static func inDefaultTerminal(_ command: String) async throws {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: GhosttyLocator.bundleIdentifier) != nil {
            _ = try await TerminalLocator.runAppleScript(ghosttyScript(command), target: "Ghostty")
        } else {
            _ = try await TerminalLocator.runAppleScript(terminalScript(command), target: "Terminal")
        }
    }

    /// 在最近活动的客户端所在的 tmux 会话里开个新窗口跑，再把那个终端带到前台。没有 tmux 或没有客户端返回 false。
    @MainActor
    private static func inTmux(_ session: SessionRecord) async throws -> Bool {
        let shellCommand = "\(tool(for: session)) \(shellQuote(session.sessionId))"
        let cwd = session.cwd
        let client = await Task.detached(priority: .userInitiated) { () -> TmuxLocator.Client? in
            guard let tmux = TmuxLocator.binary(),
                  let client = TmuxLocator.client(session: nil, listing: TmuxLocator.run(tmux, ["list-clients", "-F", TmuxLocator.clientFormat]))
            else { return nil }
            TmuxLocator.run(tmux, ["new-window", "-t", client.session, "-c", cwd, shellCommand])
            return client
        }.value
        guard let client else { return false }
        try await TmuxLocator.focusHost(of: client)
        return true
    }
}
