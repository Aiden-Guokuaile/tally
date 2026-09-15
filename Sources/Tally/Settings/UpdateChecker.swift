import Foundation
import Observation

/// 新版本提示：启动时和之后每 24 小时问一次 GitHub 上的最新 Release，比自己新就在设置「通用」里显示一行、刘海里提示一次。
/// 只提示不替换：分发的 DMG 是 ad-hoc 签名，下载下来验不了真假，自动换掉等于替人跑一个没法验证的程序。
@MainActor
@Observable
final class UpdateChecker {

    static let shared = UpdateChecker()

    static let latestURL = URL(string: "https://api.github.com/repos/guokuaile/tally/releases/latest")!
    static let interval: TimeInterval = 24 * 3600

    struct Release: Equatable {
        let version: String
        let page: URL
    }

    /// 比当前版本新的那个 Release；没有或没查过为 nil。
    private(set) var available: Release?
    private(set) var lastChecked: Date?
    private(set) var checking = false
    /// 上一次没查成的原因，设置页显示；查成了清空。
    private(set) var problem: String?
    /// 查到新版本时调，控制器决定要不要提示（同一个版本只提示一次）。
    var onNewVersion: ((Release) -> Void)?

    private let session: URLSession
    private let currentVersion: String
    private var timer: Timer?

    init(session: URLSession = URLSession(configuration: .ephemeral),
         currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0") {
        self.session = session
        self.currentVersion = currentVersion
    }

    /// 幂等：开着就保证有定时器并立刻查一次，关掉就停并清掉结果。
    func setEnabled(_ on: Bool) {
        guard on else {
            timer?.invalidate()
            timer = nil
            available = nil
            problem = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        Task { await check() }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        var request = URLRequest(url: Self.latestURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Tally", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            lastChecked = Date()
            switch status {
            case 200:
                guard let release = Self.parse(data) else {
                    problem = "GitHub 返回的版本信息看不懂"
                    return
                }
                problem = nil
                available = Self.isNewer(release.version, than: currentVersion) ? release : nil
                if let available { onNewVersion?(available) }
            case 404:
                // 还没发过 Release
                problem = nil
                available = nil
            default:
                problem = status == 403 || status == 429 ? "GitHub 限流了，过一会儿再查" : "检查新版本失败（HTTP \(status)）"
            }
        } catch {
            problem = "检查新版本失败：\(error.localizedDescription)"
        }
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              components(tag) != nil
        else { return nil }
        return Release(version: normalized(tag), page: page)
    }

    /// 「v1.2.0」→「1.2.0」；去掉 `-beta`、`+build` 这类后缀。
    nonisolated static func normalized(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return String(text.prefix { $0 != "-" && $0 != "+" })
    }

    /// 按点拆成整数；有一段不是整数就 nil（认不出的版本号不提示，免得乱报）。
    nonisolated static func components(_ version: String) -> [Int]? {
        let parts = normalized(version).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    /// 补零后逐段比：「1.0」和「1.0.0」一样，「1.10」比「1.9」新。
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = components(candidate), let b = components(current) else { return false }
        let count = max(a.count, b.count)
        let left = a + Array(repeating: 0, count: count - a.count)
        let right = b + Array(repeating: 0, count: count - b.count)
        return left.lexicographicallyPrecedes(right) == false && left != right
    }

    /// 用 Homebrew cask 装的：提示 `brew upgrade --cask tally`，别让人去下载 DMG 覆盖。
    nonisolated static func installedByHomebrew(caskrooms: [String] = ["/opt/homebrew/Caskroom/tally", "/usr/local/Caskroom/tally"]) -> Bool {
        caskrooms.contains { FileManager.default.fileExists(atPath: $0) }
    }
}
