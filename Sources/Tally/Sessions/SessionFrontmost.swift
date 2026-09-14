import AppKit
import Foundation

/// 会话的终端标签是不是正在前台：是的话提示条和提示音都免了，人正看着它（docs/panel.md「提示」）。
enum SessionFrontmost {

    static let ghosttyFocusedScript = "tell application id \"com.mitchellh.ghostty\" to return id of focused terminal of selected tab of front window"
    static let terminalSelectedTTYScript = "tell application id \"com.apple.Terminal\" to return tty of selected tab of front window"
    static let itermCurrentTTYScript = "tell application id \"com.googlecode.iterm2\" to return tty of current session of current window"

    @MainActor
    static func check(_ session: SessionRecord) async -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        switch TerminalLocator.kind(for: session.term, running: TerminalLocator.isRunning) {
        case .ghostty:
            guard front == GhosttyLocator.bundleIdentifier, hasAutomation(front),
                  let focused = try? await TerminalLocator.runAppleScript(ghosttyFocusedScript, target: "Ghostty"),
                  let terminals = try? await GhosttyLocator.terminals(),
                  case .found(let id) = GhosttyMatch.pick(terminals: terminals, cwd: session.cwd, title: session.title, provider: session.provider)
            else { return false }
            return id == focused
        case .terminalApp:
            guard front == TerminalAppLocator.bundleIdentifier, hasAutomation(front), let tty = session.tty,
                  let selected = try? await TerminalLocator.runAppleScript(terminalSelectedTTYScript, target: "Terminal")
            else { return false }
            return selected == TerminalLocator.devicePath(tty)
        case .iterm:
            guard front == ITermLocator.bundleIdentifier, hasAutomation(front), let tty = session.tty,
                  let current = try? await TerminalLocator.runAppleScript(itermCurrentTTYScript, target: "iTerm")
            else { return false }
            return current == TerminalLocator.devicePath(tty)
        case .tmux, .editor, .activate, .unknown:
            // 判不到标签，照常提示
            return false
        }
    }

    /// 已经有「控制 <app>」的自动化授权才去问；没有就当不在前台——不能为了一条提示去弹授权框。
    static func hasAutomation(_ bundleId: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return false }
        return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) == OSStatus(noErr)
    }
}
