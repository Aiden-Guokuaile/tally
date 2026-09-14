import AppKit
import Foundation
import Observation

/// 一个在跑的 app。`isHidden` 是 Dock 里看不见的那种（菜单栏工具、纯后台）。
struct RunningApp: Equatable, Identifiable {
    /// pid。
    let id: pid_t
    var name: String
    var bundleURL: URL
    var bundleIdentifier: String
    var isHidden: Bool
    var memory: UInt64?
}

enum RunningApps {

    /// 算不算、算哪种：`regular`（Dock 里看得见，⌘Tab 里那些）一律算，不管谁出的；
    /// `accessory`（菜单栏或纯后台）要装在 /Applications 或用户目录下、不是嵌在别的 app 包里的 Helper、不是苹果自己的，
    /// 才算「隐藏的」；其余（prohibited、系统的后台 accessory）不算。Tally 自己也按这套算：平时是 accessory，开着设置窗口时是 regular。
    static func isHidden(policy: NSApplication.ActivationPolicy, bundlePath: String, bundleIdentifier: String, home: String) -> Bool? {
        if policy == .regular { return false }
        guard policy == .accessory else { return nil }
        guard bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix(home + "/") else { return nil }
        // 只有一层 .app：嵌在别的 app 包里的 Helper 路径里会出现两次
        let nested = bundlePath.components(separatedBy: ".app/").count - 1 + (bundlePath.hasSuffix(".app") ? 1 : 0)
        guard nested == 1 else { return nil }
        guard !bundleIdentifier.hasPrefix("com.apple.") else { return nil }
        return true
    }

    /// 按内存降序，同样大按名字。
    static func list(footprint: (pid_t) -> UInt64? = SystemSampler.footprint) -> [RunningApp] {
        let home = NSHomeDirectory()
        return NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard let url = app.bundleURL, let identifier = app.bundleIdentifier,
                  let hidden = isHidden(policy: app.activationPolicy, bundlePath: url.path, bundleIdentifier: identifier, home: home)
            else { return nil }
            return RunningApp(id: app.processIdentifier, name: app.localizedName ?? identifier, bundleURL: url,
                              bundleIdentifier: identifier, isHidden: hidden, memory: footprint(app.processIdentifier))
        }
        .sorted { ($0.memory ?? 0, $1.name) > ($1.memory ?? 0, $0.name) }
    }
}

/// 「应用」页的状态：停在这页时每 2 秒重新列一次（内存会变，app 会来去）。
///
/// 列举、读内存、取图标全在后台跑，主线程只收结果：`NSRunningApplication.icon` 一个要 3.5 ms（32 个尺寸、最大 2048px），
/// 十几行就是 50 ms，放在视图 body 里每次刷新、每次悬停都重来，切页时正好卡在高度动画里。图标按 pid 缓存，缩成 36px 小图。
@MainActor
@Observable
final class RunningAppsStore {

    static let shared = RunningAppsStore()

    private(set) var apps: [RunningApp] = []
    /// 按 pid 缓存的小图标，进程没了就丢。
    private(set) var icons: [pid_t: NSImage] = [:]
    private var timer: Timer?
    /// 晚回来的旧一轮不能盖住新一轮。
    private var generation = 0

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 标题行的刷新按钮。
    func refreshNow() {
        guard timer != nil else { return }
        tick()
    }

    private func tick() {
        generation += 1
        let mine = generation
        let known = Set(icons.keys)
        Task.detached(priority: .userInitiated) {
            let list = RunningApps.list()
            var fresh: [pid_t: NSImage] = [:]
            for app in list where !known.contains(app.id) {
                fresh[app.id] = Self.smallIcon(pid: app.id, bundleURL: app.bundleURL)
            }
            let freshIcons = fresh
            await MainActor.run {
                guard self.generation == mine else { return }
                self.apps = list
                let alive = Set(list.map(\.id))
                self.icons = self.icons.filter { alive.contains($0.key) }.merging(freshIcons) { _, new in new }
            }
        }
    }

    /// 页里画的尺寸是 18pt，缓存一张 36px 的位图就够；原图 32 个尺寸、最大 2048px，每次画都要重采样。
    nonisolated static func smallIcon(pid: pid_t, bundleURL: URL) -> NSImage {
        let source = NSRunningApplication(processIdentifier: pid)?.icon ?? NSWorkspace.shared.icon(forFile: bundleURL.path)
        let size = 36
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return source }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let scaled = context.makeImage() else { return source }
        return NSImage(cgImage: scaled, size: NSSize(width: 18, height: 18))
    }

    /// 激活并触发 reopen，菜单栏 app 通常会弹出主窗口。
    func open(_ app: RunningApp) {
        NSWorkspace.shared.openApplication(at: app.bundleURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { Log.error("打开 \(app.name) 失败: \(error.localizedDescription)") }
        }
    }

    /// 「Updater」「Helper」这类通用名字看不出是谁的东西，路径里才有归属（如 Caches/com.tencent.xinWeChat/…）。
    /// 面板不抢激活，AppKit 的悬停提示画不出来，所以走访达。
    func reveal(_ app: RunningApp) {
        NSWorkspace.shared.activateFileViewerSelecting([app.bundleURL])
    }

    /// 正常退出，不强杀；对方拒绝就记一笔，下一次刷新它还在。列表里也有 Tally 自己，`terminate()` 对当前进程无效，走 NSApp。
    func quit(_ app: RunningApp) {
        if app.id == ProcessInfo.processInfo.processIdentifier {
            NSApp.terminate(nil)
            return
        }
        if NSRunningApplication(processIdentifier: app.id)?.terminate() != true {
            Log.error("\(app.name) 没接受退出请求")
        }
    }
}
