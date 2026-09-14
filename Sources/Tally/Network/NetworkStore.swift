import AppKit
import Foundation
import Network
import Observation

struct ProxyGroup: Equatable {
    let name: String
    /// 组当前选中的成员，可能是另一个组的名字，那是用户配的，原样显示。
    let now: String
}

/// mihomo 内核接口那一段的状态。
enum ProxyState: Equatable {
    case notRunning
    case running(mode: String?, tun: Bool?, groups: [ProxyGroup])
}

/// 主接口的一切：名字、IPv4、网关、DNS、Wi-Fi 信号（不是 Wi-Fi 为 nil）。
struct InterfaceInfo: Equatable {
    var name: String
    var address: String?
    var router: String?
    var dns: [String]
    var wifi: WiFiInfo?
}

/// 代理卡片：系统代理设置人人都有；内核接口那段只在 socket 存在时有，`core` 为 nil 是没有接口或还没判完。
struct ProxyInfo: Equatable {
    var settings: ProxySettings
    /// mihomo 内核的 socket 文件在不在；在才去拉模式与组。
    var coreAvailable: Bool
    var core: ProxyState?
    /// 在跑的代理软件，端口反查或名单认出来的；nil 是没有或还没查完。
    var app: ProxyApp?
}

/// 网络页的状态：网卡计数每秒差分出速率，主接口与代理每 10 秒刷一次。
///
/// 速率不依赖任何代理软件；mihomo 内核的 socket 存在时才向它发 `/configs`、`/proxies`。
@MainActor
@Observable
final class NetworkStore {

    static let shared = NetworkStore()

    nonisolated static let maxGroups = 6
    nonisolated static let historyLength = 60

    /// 字节/秒；还没量到（第一秒，或网卡计数取不到）是 nil，页面显示「—」。
    private(set) var up: Int?
    private(set) var down: Int?
    /// 最近 60 秒，新的在后。
    private(set) var history: [(up: Int, down: Int)] = []
    private(set) var primary: InterfaceInfo?
    private(set) var proxy: ProxyInfo?

    private let client: MihomoRequesting
    private let coreSocketExists: () -> Bool
    /// 每次刷新快照时查一次 socket 文件在不在；在才发请求、才画那一段。
    private var coreAvailable = false
    private var started = false
    private var previous: (counters: InterfaceCounters, at: Date)?
    private var rateTimer: Timer?
    private var snapshotTimer: Timer?
    private var connections: [NWConnection] = []
    /// 每轮 fetchProxy 加一；上一轮的回调看到编号不对就作废。
    private var generation = 0
    /// 端口反查在后台，同样按轮次作废；stop 时取消，别让 lsof 的结果在收起后还写状态。
    private var appGeneration = 0
    private var appTask: Task<Void, Never>?

    init(client: MihomoRequesting = MihomoClient(), coreSocketExists: @escaping () -> Bool = NetworkStore.defaultCoreSocketExists) {
        self.client = client
        self.coreSocketExists = coreSocketExists
    }

    nonisolated static func defaultCoreSocketExists() -> Bool {
        FileManager.default.fileExists(atPath: MihomoClient.defaultSocketPath)
    }

    func start() {
        guard !started else { return }
        started = true
        if DemoMode.isOn { return startDemo() }
        tick()
        refreshSnapshot()
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSnapshot() }
        }
    }

    func stop() {
        started = false
        rateTimer?.invalidate()
        rateTimer = nil
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        appTask?.cancel()
        appTask = nil
        previous = nil
        history = []
        up = nil
        down = nil
        Log.debug("网络采样停止")
    }

    /// 演示模式：接口与代理是假的，速率每秒按时间算一个点。定时器挂在 `rateTimer` 上，`stop()` 照常收；
    /// `stop()` 会清掉曲线，所以每次开页先补满 60 秒，不然截图里的图只有右边一小截。
    private func startDemo() {
        primary = DemoData.interface
        proxy = DemoData.proxy
        let now = Date().timeIntervalSince1970
        for secondsAgo in stride(from: Self.historyLength - 1, through: 0, by: -1) {
            record(DemoData.throughput(at: now - Double(secondsAgo)))
        }
        rateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.record(DemoData.throughput(at: Date().timeIntervalSince1970)) }
        }
    }

    /// 标题行的刷新按钮：速率立刻差分一次，接口与代理立刻重拉。演示模式不动：重拉会把真网卡、真 IP 换上来。
    func refreshNow() {
        guard started, !DemoMode.isOn else { return }
        tick()
        refreshSnapshot()
    }

    /// 每秒一次：取不到计数就跳过这一秒，值保持上一秒的。
    private func tick() {
        guard let current = InterfaceSampler.counters() else { return }
        let now = Date()
        if let previous {
            record(InterfaceSampler.rate(previous: previous.counters, current: current, elapsed: now.timeIntervalSince(previous.at)))
        }
        previous = (current, now)
    }

    func record(_ sample: (up: Int, down: Int)) {
        up = sample.up
        down = sample.down
        history.append(sample)
        if history.count > Self.historyLength {
            history.removeFirst(history.count - Self.historyLength)
        }
    }

    func refreshSnapshot() {
        primary = InterfaceSampler.primary().map {
            InterfaceInfo(name: $0.name, address: $0.address, router: $0.router,
                          dns: InterfaceSampler.dns(), wifi: InterfaceSampler.wifi(interface: $0.name))
        }
        let settings = InterfaceSampler.systemProxy()
        coreAvailable = coreSocketExists()
        proxy = ProxyInfo(settings: settings, coreAvailable: coreAvailable, core: coreAvailable ? proxy?.core : nil, app: proxy?.app)
        detectProxyApp(settings: settings)
        guard coreAvailable else { return }
        fetchProxy()
    }

    /// lsof 反查要几十毫秒，放后台；回来时轮次不对或已经停了就丢掉。
    private func detectProxyApp(settings: ProxySettings) {
        appGeneration += 1
        let mine = appGeneration
        appTask?.cancel()
        appTask = Task.detached(priority: .utility) {
            let app = ProxyAppDetector.detect(settings: settings)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.started, self.appGeneration == mine else { return }
                self.proxy?.app = app
            }
        }
    }

    /// 两个短连接一起发，都回来了再一起判：任一失败就是「未运行」。
    /// 上一轮还没回来的先作废：慢响应不能拿旧数据盖新数据，挂死的连接也不能越攒越多。
    private func fetchProxy() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        generation += 1
        let mine = generation
        var configs = Data()
        var proxies = Data()
        var pending = 2
        var failed = false
        let settle: (Error?) -> Void = { [weak self] error in
            guard let self, self.started, self.generation == mine else { return }
            if error != nil { failed = true }
            pending -= 1
            guard pending == 0 else { return }
            guard !failed, let parsedConfigs = Self.parseConfigs(configs), let groups = Self.parseProxies(proxies) else {
                self.proxy?.core = .notRunning
                return
            }
            self.proxy?.core = .running(mode: parsedConfigs.mode, tun: parsedConfigs.tun, groups: groups)
        }
        let a = client.get("/configs", onLine: { configs.append($0) }, onClose: settle)
        let b = client.get("/proxies", onLine: { proxies.append($0) }, onClose: settle)
        connections.append(contentsOf: [a, b].compactMap { $0 })
    }

    // MARK: 解析（纯函数，测试直接调）

    nonisolated static func parseConfigs(_ data: Data) -> (mode: String?, tun: Bool?)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tun = (object["tun"] as? [String: Any])?["enable"] as? Bool
        return (object["mode"] as? String, tun)
    }

    /// 顶层 `proxies` 字典里 `type == "Selector"` 且不是 GLOBAL 的组，按 `GLOBAL.all` 的次序（就是配置顺序），
    /// 不在其中的丢掉，最多 `maxGroups` 个。
    nonisolated static func parseProxies(_ data: Data) -> [ProxyGroup]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = object["proxies"] as? [String: Any] else { return nil }
        let order = (proxies["GLOBAL"] as? [String: Any])?["all"] as? [String] ?? []
        var result: [ProxyGroup] = []
        for name in order where name != "GLOBAL" {
            guard let entry = proxies[name] as? [String: Any],
                  entry["type"] as? String == "Selector",
                  let now = entry["now"] as? String else { continue }
            result.append(ProxyGroup(name: name, now: now))
            if result.count == maxGroups { break }
        }
        return result
    }
}
