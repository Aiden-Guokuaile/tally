import Foundation

/// hook 最近一次收到的事件，按提供方各一个文件，放在会话目录的上一层——会话目录被 kqueue 盯着，
/// 写在里面的话每次工具调用都会让 app 重读一遍目录。设置页据此显示「最近收到事件：3 分钟前（Stop）」，
/// 分清「hook 没被调用」和「调用了但界面没显示」。
public struct HookHeartbeat: Codable, Equatable {
    public var event: String
    /// 毫秒时间戳。
    public var at: Double
    /// Claude 侧收到事件时 Claude Code 进程里的 `CLAUDE_CONFIG_DIR`：hook 继承的是 Claude Code 的真实环境，
    /// 只写在 `.zshrc` 里的变量登录 shell 问不出来（zsh 非交互不读它），app 靠这份记录补上。
    public var claudeConfigDir: String?

    public init(event: String, at: Double, claudeConfigDir: String? = nil) {
        self.event = event
        self.at = at
        self.claudeConfigDir = claudeConfigDir
    }

    public static func url(sessionsDirectory: URL, provider: String) -> URL {
        sessionsDirectory.deletingLastPathComponent().appendingPathComponent("hook-last-\(provider).json")
    }

    public static func read(sessionsDirectory: URL, provider: String) -> HookHeartbeat? {
        guard let data = try? Data(contentsOf: url(sessionsDirectory: sessionsDirectory, provider: provider)) else { return nil }
        return try? JSONDecoder().decode(HookHeartbeat.self, from: data)
    }

    public func write(sessionsDirectory: URL, provider: String) throws {
        let file = Self.url(sessionsDirectory: sessionsDirectory, provider: provider)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}
