import AppKit
import Foundation

/// Ghostty 通过 AppleScript 暴露的一个终端。
struct GhosttyTerminal: Equatable {
    let id: String
    let name: String
    let workingDirectory: String
}

/// 从终端列表里挑出会话对应的那一个。纯函数，便于测试。
enum GhosttyMatch: Equatable {
    case found(id: String)
    case notFound

    /// 顺序：
    /// 1. 有会话标题就先按标题找（Claude 的终端标题是「状态符号 + 空格 + 会话标题」）。恰好一个就是它；
    ///    多个再用工作目录挑。标题优先是因为 hook 记的 cwd 会跟着会话里的 `cd` 走，
    ///    而终端报的是 shell 的目录，两者经常不一样。
    /// 2. 没标题或标题没命中：按工作目录取候选，精确相等优先，其次终端目录是会话目录的祖先
    ///    （会话在子目录里干活时就是这种情况），祖先里取最深的那层。
    /// 3. 候选仍多于一个且没有会话标题时（Codex 不起会话标题，终端标题是「状态符号 + 空格 + 目录名」），
    ///    用目录名再筛一次。
    /// 4. 取第一个（Ghostty 返回的第一个窗口是最前面的）；一个都没有返回 notFound。
    static func pick(terminals: [GhosttyTerminal], cwd: String, title: String?, provider: String = "claude") -> GhosttyMatch {
        let target = normalize(cwd)
        let cleanTitle = title?.trimmingCharacters(in: .whitespaces) ?? ""

        if !cleanTitle.isEmpty {
            let byTitle = terminals.filter { matchesTitle($0.name, cleanTitle) }
            if byTitle.count == 1 { return .found(id: byTitle[0].id) }
            if byTitle.count > 1 {
                let narrowed = directoryCandidates(in: byTitle, target: target)
                return .found(id: (narrowed.isEmpty ? byTitle : narrowed)[0].id)
            }
        }

        var candidates = directoryCandidates(in: terminals, target: target)
        guard !candidates.isEmpty else { return .notFound }
        if candidates.count > 1, cleanTitle.isEmpty {
            let dirName = URL(fileURLWithPath: target).lastPathComponent
            let narrowed = candidates.filter { matchesTitle($0.name, dirName) }
            if !narrowed.isEmpty { candidates = narrowed }
        }
        return .found(id: candidates[0].id)
    }

    /// 精确相等的终端；没有就取目录是 `target` 祖先的终端里最深的那一层。
    static func directoryCandidates(in terminals: [GhosttyTerminal], target: String) -> [GhosttyTerminal] {
        let normalized = terminals.map { ($0, normalize($0.workingDirectory)) }
        let exact = normalized.filter { $0.1 == target }.map(\.0)
        if !exact.isEmpty { return exact }
        let ancestors = normalized.filter { isAncestor($0.1, of: target) }
        guard let deepest = ancestors.map({ $0.1.count }).max() else { return [] }
        return ancestors.filter { $0.1.count == deepest }.map(\.0)
    }

    /// `/a/b` 是 `/a/b/c` 的祖先；`/a/b` 不是 `/a/bc` 的祖先；根目录 `/` 是所有路径的祖先。
    static func isAncestor(_ directory: String, of path: String) -> Bool {
        if directory == "/" { return path != "/" }
        return path.hasPrefix(directory + "/")
    }

    /// 标题正文等于 needle，或以「空格 + needle」结尾（前面是状态符号）。
    static func matchesTitle(_ name: String, _ needle: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed == needle || trimmed.hasSuffix(" " + needle)
    }

    /// `/tmp` 与 `/private/tmp` 视为相同。
    static func normalize(_ path: String) -> String {
        var resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        while resolved.count > 1, resolved.hasSuffix("/") { resolved.removeLast() }
        return resolved
    }
}

/// 真正去问 Ghostty。Info.plist 有 NSAppleEventsUsageDescription，首次会弹自动化授权。
@MainActor
enum GhosttyLocator {

    static let bundleIdentifier = "com.mitchellh.ghostty"

    enum Failure: Error, Equatable {
        case ghosttyNotRunning
        case scriptFailed(String)
        case notFound
    }

    /// 分隔符在 tell 块外取：Ghostty 的字典里有 `tab` 类，块内写 `tab` 会被它遮蔽，
    /// 拼出来是字面量 "tab" 而不是制表符（实测踩过）。
    private static let listScript = """
    set sep to character id 9
    tell application id "com.mitchellh.ghostty"
        set out to ""
        repeat with w in windows
            repeat with t in terminals of w
                set out to out & (id of t) & sep & (name of t) & sep & (working directory of t) & linefeed
            end repeat
        end repeat
        return out
    end tell
    """

    private static func runningGhostty() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    static func terminals() async throws -> [GhosttyTerminal] {
        // 不在跑就不问：`tell application` 会把它拉起来。
        guard runningGhostty() != nil else { throw Failure.ghosttyNotRunning }
        let output = try await execute(listScript)
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return GhosttyTerminal(id: String(parts[0]), name: String(parts[1]), workingDirectory: String(parts[2]))
        }
    }

    /// 找到就聚焦并把 Ghostty 激活。
    static func focus(session: SessionRecord) async throws {
        let list = try await terminals()
        guard case .found(let id) = GhosttyMatch.pick(
            terminals: list, cwd: session.cwd, title: session.title, provider: session.provider
        ) else {
            throw Failure.notFound
        }
        let escaped = id.replacingOccurrences(of: "\"", with: "\\\"")
        _ = try await execute("tell application id \"com.mitchellh.ghostty\" to focus terminal id \"\(escaped)\"")
        runningGhostty()?.activate()
        Log.debug("聚焦终端 \(id)")
    }

    /// 和 Terminal / iTerm 走同一个执行器：后台跑（授权框弹出时主线程不能卡住）、
    /// 未授权与超时单独翻译，TerminalLocator 的 ghostty 分支把它原样往上抛。
    private static func execute(_ source: String) async throws -> String {
        try await TerminalLocator.runAppleScript(source, target: "Ghostty")
    }
}
