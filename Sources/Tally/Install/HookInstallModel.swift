import Foundation
import Observation

/// 设置页「hook」两行的状态与动作。安装是用户点了按钮才做，Codex 那侧要跑 app-server，放后台。
@MainActor
@Observable
final class HookInstallModel {

    static let shared = HookInstallModel(installer: HookInstaller.live())

    private(set) var statuses: [HookSide: HookStatus] = [:]
    private(set) var busy: Set<HookSide> = []
    private(set) var errors: [HookSide: String] = [:]
    /// 每侧 hook 最近一次收到的事件；打开设置页、点自检时刷新。
    private(set) var heartbeats: [HookSide: HookHeartbeat] = [:]
    /// 每侧自检结果，一句人话；没点过为 nil。
    private(set) var selfTests: [HookSide: String] = [:]

    let installer: HookInstaller

    init(installer: HookInstaller) {
        self.installer = installer
    }

    func refresh() {
        let sessions = PreferencesStore.directory.appendingPathComponent("sessions")
        for side in HookSide.allCases {
            statuses[side] = installer.status(side)
            heartbeats[side] = HookHeartbeat.read(sessionsDirectory: sessions, provider: side.provider)
        }
    }

    /// 自检：把写进配置的那条命令原样交给 /bin/sh 跑一条模拟事件（`HookSelfTest`），子进程放后台。
    /// 没装好就不跑：配置里不是这条命令的话，二进制跑通了也证明不了 agent 调得通。
    func selfTest(_ side: HookSide) {
        guard !busy.contains(side) else { return }
        guard installer.status(side) == .installed else {
            selfTests[side] = "还没装好：先点上面的「安装」，自检跑的是配置里的那条命令"
            return
        }
        busy.insert(side)
        let command = installer.expectedCommand(side)
        Task.detached {
            let result = HookSelfTest.run(command: command)
            await MainActor.run {
                self.busy.remove(side)
                self.selfTests[side] = result
                self.refresh()
            }
        }
    }

    /// 「最近收到事件：3 分钟前（Stop）」。
    nonisolated static func describeHeartbeat(_ heartbeat: HookHeartbeat?, now: Date) -> String {
        guard let heartbeat else { return "还没收到过事件：装之前就开着的会话要重开一次才会挂上" }
        let seconds = max(0, Int(now.timeIntervalSince1970 - heartbeat.at / 1000))
        let ago: String
        switch seconds {
        case ..<60: ago = "刚刚"
        case ..<3600: ago = "\(seconds / 60) 分钟前"
        case ..<86400: ago = "\(seconds / 3600) 小时前"
        default: ago = "\(seconds / 86400) 天前"
        }
        return "最近收到事件：\(ago)（\(heartbeat.event)）"
    }

    func install(_ side: HookSide) {
        guard !busy.contains(side) else { return }
        busy.insert(side)
        errors[side] = nil
        let installer = self.installer
        Task.detached {
            let failure: String?
            do {
                try installer.install(side)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.busy.remove(side)
                if let failure {
                    self.errors[side] = failure + "\n" + HookInstaller.manualSteps(side, hookBinary: installer.hookBinary)
                }
                self.refresh()
            }
        }
    }

    /// 移除注册；Codex 侧还要重写别的 hook 的信任哈希，放后台。
    func uninstall(_ side: HookSide) {
        guard !busy.contains(side) else { return }
        busy.insert(side)
        errors[side] = nil
        let installer = self.installer
        Task.detached {
            let failure: String?
            do {
                try installer.uninstall(side)
                failure = nil
            } catch {
                failure = "移除时出错：" + error.localizedDescription
            }
            await MainActor.run {
                self.busy.remove(side)
                if let failure { self.errors[side] = failure }
                self.refresh()
            }
        }
    }

    /// `--install-hooks` 启动参数用：同步装两侧，返回每侧的结果文本。
    func installAllBlocking() -> [String] {
        HookSide.allCases.map { side in
            do {
                try installer.install(side)
                return "\(side.title): \(Self.describe(installer.status(side)))"
            } catch {
                return "\(side.title): 失败 \(error.localizedDescription)"
            }
        }
    }

    static func describe(_ status: HookStatus?) -> String {
        switch status {
        case .installed: return "已安装"
        case .missing: return "未安装"
        case .pointsElsewhere(let why): return "需要更新（\(why)）"
        case nil: return "未知"
        }
    }
}

/// hook 自检：喂一条模拟的 SessionStart，状态目录指到临时目录，看它能不能跑完并写出文件（docs/hooks.md「自检」）。
enum HookSelfTest {

    /// `command` 是写进配置的那条（带引号的路径，Codex 侧后面跟 --provider codex），和 agent 调它时一样交给 /bin/sh。
    static func run(command: String) -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tally-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let input = root.appendingPathComponent("event.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(#"{"session_id":"tally-selftest","hook_event_name":"SessionStart","cwd":"/tmp"}"#.utf8).write(to: input)
        } catch {
            return "临时目录写不进去：\(error.localizedDescription)"
        }
        var environment = ProcessInfo.processInfo.environment
        environment["TALLY_SESSIONS_DIR"] = sessions.path
        environment["TALLY_SELFTEST_INPUT"] = input.path
        // stdin 走文件重定向：hook 要把 stdin 读到结束，Subprocess 给的管道一直开着，直接喂会等到 900 ms 自退、什么都不写
        // exec 让 hook 顶替 sh：被信号杀掉时才看得出来，不然退出状态会变成 sh 的 128+n
        let arguments = ["-c", "exec \(command) < \"$TALLY_SELFTEST_INPUT\""]
        let started = Date()
        let result: Subprocess.Result
        do {
            result = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), arguments, environment: environment, deadline: 3)
        } catch {
            return "跑不起来：\(error.localizedDescription)"
        }
        let wrote = FileManager.default.fileExists(atPath: sessions.appendingPathComponent("tally-selftest.json").path)
        return describe(timedOut: result.timedOut, status: result.status, wrote: wrote,
                        milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                        stderr: String(decoding: result.stderr, as: UTF8.self))
    }

    static func describe(timedOut: Bool, status: Int32?, wrote: Bool, milliseconds: Int, stderr: String) -> String {
        if timedOut { return "3 秒没退出：hook 卡住了，agent 那边会一直等到 hook 超时" }
        guard let status else { return "被信号杀掉了：常见于 app 被系统隔离，重新从「应用程序」打开一次" }
        guard status == 0 else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "退出码 \(status)" + (detail.isEmpty ? "" : "：\(detail.prefix(120))")
        }
        guard wrote else { return "跑完了但没写出状态文件：会话目录可能没有写权限" }
        return "正常：\(milliseconds) ms 跑完并写出状态文件"
    }
}
