import AppKit
import Foundation

/// iTerm2：字典是 application → window → tab → session，session 有 `tty`。
/// 用 `application id` 不用名字：这个 app 的文件叫 iTerm.app、CFBundleName 却是 iTerm2，
/// 按名字找碰上改过名的安装会解析不到，AppleScript 会弹「选择应用程序」或直接报错。
enum ITermLocator {

    static let bundleIdentifier = "com.googlecode.iterm2"

    @MainActor
    static func focus(tty: String?) async throws {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            throw TerminalLocator.Failure.notRunning("iTerm2")
        }
        guard let tty, !tty.isEmpty else { throw TerminalLocator.Failure.notFound }
        let device = TerminalLocator.devicePath(tty)
        let script = """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(device)" then
                            select s
                            select t
                            select w
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "none"
        end tell
        """
        // 原来只 select 会话、不选窗口也不 activate：命中了也只是「标签选中了但窗口没到前台」
        guard try await TerminalLocator.runAppleScript(script, target: "iTerm") == "ok" else { throw TerminalLocator.Failure.notFound }
        _ = app
    }
}
