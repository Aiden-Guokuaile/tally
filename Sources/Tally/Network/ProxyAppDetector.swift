import AppKit
import Foundation

/// 在跑的代理软件。
struct ProxyApp: Equatable {
    var name: String
    var bundleIdentifier: String?
    var bundleURL: URL?
    var pid: pid_t

    init(name: String, bundleIdentifier: String?, bundleURL: URL?, pid: pid_t) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.pid = pid
    }

    init(_ app: NSRunningApplication) {
        self.init(name: app.localizedName ?? app.bundleIdentifier ?? "代理",
                  bundleIdentifier: app.bundleIdentifier, bundleURL: app.bundleURL, pid: app.processIdentifier)
    }
}

/// 端口反查优先（对任何代理软件都成立），名单兜底。
enum ProxyAppDetector {

    static let knownBundleIdentifiers = [
        "com.aiden.gauge",                              // Watchdog
        "com.west2online.ClashX",                       // ClashX
        "com.metacubex.ClashX",                         // ClashX Meta
        "io.github.clash-verge-rev.clash-verge-rev",    // Clash Verge
        "party.mihomo.app",                             // mihomo-party
        "com.nssurge.surge-mac",                        // Surge
        "yanue.V2rayU",                                 // V2rayU
        "com.qiuyuzhou.ShadowsocksX-NG",                // ShadowsocksX-NG
    ]

    /// `127.0.0.1:7899` → 7899；指向别的主机的代理不是本机进程，返回 nil，不去反查本地端口。
    static func localPort(of endpoint: String?) -> Int? {
        guard let endpoint, let colon = endpoint.lastIndex(of: ":") else { return nil }
        let host = String(endpoint[..<colon])
        guard ["127.0.0.1", "localhost", "::1", "0.0.0.0"].contains(host) else { return nil }
        return Int(endpoint[endpoint.index(after: colon)...])
    }

    /// 已知名单里第一个在跑的 bundle id。
    static func knownRunning(among identifiers: [String]) -> String? {
        knownBundleIdentifiers.first { identifiers.contains($0) }
    }

    /// 终端和编辑器：命令行代理从它们里面启动时，往上走会停在它们，那不是代理软件。
    static let hostAppIdentifiers: Set<String> = [
        "com.mitchellh.ghostty", "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm", "dev.warp.Warp-Stable", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]

    /// lsof 反查监听端口的 pid，本机 55 毫秒左右；后台线程调。stderr 直接丢掉（不读满了会卡死），最多等 3 秒。
    static func listeningPid(port: Int) -> pid_t? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            Log.error("lsof 3 秒没回来，放弃这次端口反查")
            return nil
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in output.split(separator: "\n") where line.hasPrefix("p") {
            return pid_t(line.dropFirst())
        }
        return nil
    }

    /// 从 pid 往父进程走，直到某个 pid 是 app（内核常是 app 的子进程）。最多走 8 层，到 launchd 就放弃。
    static func owningApplicationPid(of pid: pid_t, table: ProcessTable, isApplication: (pid_t) -> Bool) -> pid_t? {
        let parents = Dictionary(table.entries().map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        var current = pid
        var hops = 0
        while current > 1, hops < 8 {
            if isApplication(current) { return current }
            guard let parent = parents[current] else { return nil }
            current = parent
            hops += 1
        }
        return nil
    }

    static func detect(settings: ProxySettings, table: ProcessTable = SysctlProcessTable()) -> ProxyApp? {
        if let port = localPort(of: settings.http ?? settings.https ?? settings.socks),
           let listener = listeningPid(port: port),
           let appPid = owningApplicationPid(of: listener, table: table, isApplication: { NSRunningApplication(processIdentifier: $0) != nil }),
           let app = NSRunningApplication(processIdentifier: appPid),
           !hostAppIdentifiers.contains(app.bundleIdentifier ?? "") {
            return ProxyApp(app)
        }
        let running = NSWorkspace.shared.runningApplications
        guard let identifier = knownRunning(among: running.compactMap(\.bundleIdentifier)),
              let app = running.first(where: { $0.bundleIdentifier == identifier }) else { return nil }
        return ProxyApp(app)
    }

    /// 运行中的程序自己报的图标（和 ⌘Tab、它的关于窗口一致），拿不到再退回包里的文件图标。
    static func icon(of app: ProxyApp) -> NSImage? {
        NSRunningApplication(processIdentifier: app.pid)?.icon
            ?? app.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// 激活并触发它的 reopen，菜单栏 app 通常会弹出主窗口。
    static func open(_ app: ProxyApp) {
        if let url = app.bundleURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Log.error("打开 \(app.name) 失败: \(error.localizedDescription)") }
            }
        } else if NSRunningApplication(processIdentifier: app.pid)?.activate() != true {
            Log.error("激活 \(app.name)（pid \(app.pid)）失败")
        }
    }
}
