import AppKit
import Foundation

/// tmux 里的会话：agent 的 tty 就是 pane 的 tty。按它找到 pane，找挂着这个 tmux 会话的客户端切过去，
/// 再把客户端所在的终端 app 带到前台。
enum TmuxLocator {

    struct Client: Equatable {
        let tty: String
        let pid: Int32
        /// 客户端当前挂的 tmux 会话名。
        let session: String
    }

    static let paneFormat = "#{pane_tty}\t#{pane_id}\t#{session_name}"
    static let clientFormat = "#{client_tty}\t#{client_pid}\t#{client_session}\t#{client_activity}"

    /// 常见安装位置，都没有再问登录 shell：app 自己的 PATH 里只有系统目录。
    static func binary() -> URL? {
        for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return LoginShell.lines("-lc", "command -v tmux")
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// `list-panes -a` 输出里 tty 对上的那个 pane。
    static func pane(tty: String, listing: String) -> (id: String, session: String)? {
        let device = TerminalLocator.devicePath(tty)
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3, parts[0] == device { return (parts[1], parts[2]) }
        }
        return nil
    }

    /// `list-clients` 输出里挑一个客户端：挂在指定 tmux 会话上的优先，其次最近活动的。
    static func client(session: String?, listing: String) -> Client? {
        let rows: [(client: Client, activity: Int)] = listing.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, let pid = Int32(parts[1]) else { return nil }
            return (Client(tty: parts[0], pid: pid, session: parts[2]), Int(parts[3]) ?? 0)
        }
        let preferred = rows.filter { $0.client.session == session }
        return (preferred.isEmpty ? rows : preferred).max { $0.activity < $1.activity }?.client
    }

    @MainActor
    static func focus(session: SessionRecord) async throws {
        guard let tty = session.tty, !tty.isEmpty else { throw TerminalLocator.Failure.notFound }
        // tmux 命令和问登录 shell 都是同步子进程，放后台跑
        let host = try await Task.detached(priority: .userInitiated) { () throws -> Client in
            guard let tmux = binary() else { throw TerminalLocator.Failure.notRunning("tmux") }
            guard let target = pane(tty: tty, listing: run(tmux, ["list-panes", "-a", "-F", paneFormat])) else {
                throw TerminalLocator.Failure.notFound
            }
            guard let attached = client(session: target.session, listing: run(tmux, ["list-clients", "-F", clientFormat])) else {
                throw TerminalLocator.Failure.notRunning("tmux 客户端")
            }
            run(tmux, ["switch-client", "-c", attached.tty, "-t", target.id])
            run(tmux, ["select-window", "-t", target.id])
            run(tmux, ["select-pane", "-t", target.id])
            return attached
        }.value
        try await focusHost(of: host)
    }

    /// 客户端所在的终端：Terminal / iTerm 按客户端 tty 选中标签，别的（Ghostty 等）只激活 app。
    @MainActor
    static func focusHost(of client: Client) async throws {
        guard let app = hostApplication(pid: client.pid) else { throw TerminalLocator.Failure.notFound }
        switch app.bundleIdentifier {
        case TerminalAppLocator.bundleIdentifier:
            try await TerminalAppLocator.focus(tty: client.tty)
        case ITermLocator.bundleIdentifier:
            try await ITermLocator.focus(tty: client.tty)
        default:
            // 不用 NSRunningApplication.activate()：后台 app 调它会被协作激活规则挡掉
            guard let url = app.bundleURL else { throw TerminalLocator.Failure.notFound }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    /// 顺着父进程往上找第一个是 app 的进程：tmux 客户端 ← shell ← login ← 终端 app。
    static func hostApplication(pid: Int32) -> NSRunningApplication? {
        let parents = Dictionary(SysctlProcessTable().entries().map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        var current = pid
        for _ in 0..<16 where current > 1 {
            if let app = NSRunningApplication(processIdentifier: current), app.bundleIdentifier != nil { return app }
            guard let parent = parents[current] else { return nil }
            current = parent
        }
        return nil
    }

    /// 跑一条 tmux 命令，3 秒截止；失败给空串，调用方按找不到处理。
    @discardableResult
    static func run(_ tmux: URL, _ arguments: [String]) -> String {
        guard let result = try? Subprocess.run(tmux, arguments, deadline: 3) else { return "" }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}
