import AppKit
import Foundation

/// Terminal.app：字典里每个 tab 有 `tty` 属性，按会话记录里的 tty 精确找。
/// 用 `application id` 不用名字：名字会被本地化和改名影响，bundle id 不会。
enum TerminalAppLocator {

    static let bundleIdentifier = "com.apple.Terminal"

    @MainActor
    static func focus(tty: String?) async throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw TerminalLocator.Failure.notRunning("Terminal")
        }
        guard let tty, !tty.isEmpty else { throw TerminalLocator.Failure.notFound }
        let device = TerminalLocator.devicePath(tty)
        let script = """
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(device)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
            return "none"
        end tell
        """
        // 块内 activate 让 Terminal 自己到前台：后台 app 调 NSRunningApplication.activate() 会被协作激活规则挡掉
        guard try await TerminalLocator.runAppleScript(script, target: "Terminal") == "ok" else { throw TerminalLocator.Failure.notFound }
        _ = app
    }
}
