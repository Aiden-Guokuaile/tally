import Foundation
import Darwin

/// 进程表里的一行：找 agent 本体进程和它的控制终端用。
public struct ProcessEntry: Equatable {
    public let pid: Int32
    public let ppid: Int32
    /// 内核记的短名（p_comm）。Claude Code 的可执行文件叫版本号（`~/.local/share/claude/versions/2.1.263`），
    /// 所以这里可能是 "2.1.263" 而不是 "claude"，判断时还要看 `path` 和参数。
    public let comm: String
    /// 可执行文件的完整路径（proc_pidpath），拿不到时为空串。
    public let path: String
    /// 控制终端的设备号；没有控制终端（NODEV）时为 nil。
    public let tdev: Int32?

    public init(pid: Int32, ppid: Int32, comm: String, path: String = "", tdev: Int32?) {
        self.pid = pid
        self.ppid = ppid
        self.comm = comm
        self.path = path
        self.tdev = tdev
    }
}

public protocol ProcessTable {
    func entries() -> [ProcessEntry]
    /// 某个进程的 argv，用来认出 `node …/claude-code/cli.js` 这种走解释器的 agent。
    func arguments(of pid: Int32) -> [String]
}

/// 真实实现：一次 sysctl 拿全表，比逐层 spawn ps 便宜。
public struct SysctlProcessTable: ProcessTable {

    public init() {}

    public func entries() -> [ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // 两次调用之间进程数可能变，多留一点余量
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return (0..<count).map { index in
            var proc = buffer[index]
            let comm = withUnsafePointer(to: &proc.kp_proc.p_comm) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
            }
            let tdev = proc.kp_eproc.e_tdev
            return ProcessEntry(
                pid: proc.kp_proc.p_pid,
                ppid: proc.kp_eproc.e_ppid,
                comm: comm,
                path: Self.executablePath(of: proc.kp_proc.p_pid),
                tdev: tdev == -1 ? nil : tdev
            )
        }
    }

    public static func executablePath(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    /// KERN_PROCARGS2：前 4 字节是 argc，然后是可执行路径、若干个 NUL、再是各参数。
    public func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var cursor = 4
        // 跳过可执行路径
        while cursor < size, buffer[cursor] != 0 { cursor += 1 }
        while cursor < size, buffer[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        while arguments.count < argc, cursor < size {
            let start = cursor
            while cursor < size, buffer[cursor] != 0 { cursor += 1 }
            arguments.append(String(decoding: buffer[start..<cursor], as: UTF8.self))
            cursor += 1
        }
        return arguments
    }
}

/// 沿父进程链找 agent 本体（Claude Code 或 Codex 的进程）。
public enum AgentLocator {

    public struct Found: Equatable {
        public let pid: Int32
        /// 形如 `ttys003`；agent 没有控制终端时为 nil。
        public let tty: String?
    }

    static let interpreters: Set<String> = ["node", "bun", "deno"]

    /// 认 agent 的三种长相：
    /// 1. 短名或可执行文件名就是 claude / codex（Codex 的 vendor 二进制、Homebrew 装的 claude）；
    /// 2. 路径里有 `/claude/versions/`（官方安装器把二进制按版本号命名，短名变成 "2.1.263"）；
    /// 3. 走解释器跑的：node / bun / deno 的参数里带 claude-code 或 codex。
    public static func isAgent(_ entry: ProcessEntry, arguments: () -> [String]) -> Bool {
        let names: Set<String> = ["claude", "codex"]
        if names.contains(entry.comm) { return true }
        let executable = URL(fileURLWithPath: entry.path).lastPathComponent
        if names.contains(executable) { return true }
        if entry.path.contains("/claude/versions/") { return true }
        if interpreters.contains(entry.comm) || interpreters.contains(executable) {
            return arguments().contains { $0.contains("claude-code") || $0.contains("/codex") || $0.hasSuffix("codex") }
        }
        return false
    }

    /// 从 `startPid` 起最多往上 8 层。
    public static func find(startingAt startPid: Int32, in table: ProcessTable) -> Found? {
        let byPid = Dictionary(table.entries().map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var pid = startPid
        for _ in 0..<8 where pid > 1 {
            guard let entry = byPid[pid] else { return nil }
            if isAgent(entry, arguments: { table.arguments(of: entry.pid) }) {
                return Found(pid: entry.pid, tty: entry.tdev.flatMap(ttyName))
            }
            pid = entry.ppid
        }
        return nil
    }

    /// 设备号转 `ttys003`。
    public static func ttyName(_ tdev: Int32) -> String? {
        guard let name = devname(tdev, S_IFCHR) else { return nil }
        return String(cString: name)
    }
}
