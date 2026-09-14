import Foundation

/// 开机自启。抄 Watchdog 的 LaunchAgent，只改了 label。
///
/// 用用户级 LaunchAgent（`~/Library/LaunchAgents/`），不需要管理员授权。
enum LaunchAgent {

    static let label = "com.aiden.tally.launch"

    private static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        enabled ? install() : uninstall()
    }

    private static func install() -> String? {
        // 取当前 .app 的路径：Tally.app/Contents/MacOS/Tally → Tally.app
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let appPath = executable.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        guard appPath.pathExtension == "app" else {
            return "当前不是从 .app 启动的，无法设置开机自启"
        }

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>\(appPath.path)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            return "写入失败: \(error.localizedDescription)"
        }

        // 已加载过就先卸掉，否则 bootstrap 会报 already loaded
        _ = shell(["/bin/launchctl", "bootout", "gui/\(getuid())/\(label)"])
        let result = shell(["/bin/launchctl", "bootstrap", "gui/\(getuid())", plistURL.path])
        if result.contains("Bootstrap failed") {
            return "注册失败: \(result.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        Log.debug("开机自启已开启")
        return nil
    }

    private static func uninstall() -> String? {
        _ = shell(["/bin/launchctl", "bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        Log.debug("开机自启已关闭")
        return nil
    }

    @discardableResult
    private static func shell(_ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: arguments[0])
        task.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
