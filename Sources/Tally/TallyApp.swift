import SwiftUI
// TallyKit 里的模型（SessionRecord、TranscriptTitle、HookDecision）在整个 app 目标里可见，其余文件不用各自 import
@_exported import TallyKit

/// Tally —— 刘海里的 agent 会话状态与 LLM 用量。
///
/// 界面全部由 AppKit 托管（贴刘海的 NSPanel + 设置窗口），SwiftUI 只负责画内容。
/// 和 Watchdog 同一套理由：SwiftUI 的场景派窗口关掉后就拿不到 `openWindow`，
/// 而刘海面板的生命周期完全由鼠标事件驱动，必须自己管窗口。
@main
struct TallyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // App 协议要求至少有一个场景。真正的界面走 AppKit，这个占位场景永远不会被打开。
        Settings { EmptyView() }
            .commands {
                // 占位场景带出来的「设置…」点开是个空窗口，换成自己的设置窗口；设置窗口开着时 ⌘, 走这里
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") { SettingsWindowController.shared.show() }
                        .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

/// 启动参数。
///
/// `--open <page>`：`ai` / `network` / `system` / `apps` / `shelf` 让面板启动即展开到那页且不自动收起（截图验证用，不写 lastPage）；`settings` 打开设置窗口。
/// `sessions` / `usage` 是旧名字，都算 `ai`。`--install-hooks`：不开面板，同步给两侧装 hook，结果打到 stdout 后退出。
struct LaunchOptions: Equatable {
    enum Page: String, CaseIterable {
        case ai
        case network
        case system
        case apps
        case shelf
        case settings

        var title: String {
            switch self {
            case .ai: return "AI"
            case .network: return "网络"
            case .system: return "系统"
            case .apps: return "应用"
            case .shelf: return "文件架"
            case .settings: return "设置"
            }
        }

        /// 页签上的图标。
        var symbol: String {
            switch self {
            case .ai: return "sparkles"
            case .network: return "network"
            case .system: return "cpu"
            case .apps: return "square.stack.3d.up"
            case .shelf: return "tray.full"
            case .settings: return "gearshape"
            }
        }

        /// 面板里有页签的页，顺序固定；设置不是面板页。文件架要看开关，见 `visible(shelf:)`。
        static let panelPages: [Page] = [.ai, .network, .system, .apps, .shelf]

        /// 页签上实际画出来的页。
        static func visible(shelf: Bool) -> [Page] {
            shelf ? panelPages : panelPages.filter { $0 != .shelf }
        }

        init?(argument: String) {
            switch argument {
            case "ai", "sessions", "usage": self = .ai
            case "network": self = .network
            case "system": self = .system
            case "apps": self = .apps
            case "shelf": self = .shelf
            case "settings": self = .settings
            default: return nil
            }
        }
    }

    var openPage: Page?
    var installHooks = false

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            if argument == "--open", let value = iterator.next() {
                options.openPage = Page(argument: value)
            } else if argument == "--install-hooks" {
                options.installHooks = true
            }
        }
        return options
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var notch: NotchController?
    /// `open -a Tally <文件>` 顺带把 app 拉起来时，文件比 didFinishLaunching 先到，控制器还没建：先攒着。
    private var pendingFiles: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let options = LaunchOptions.parse(CommandLine.arguments)
        Log.debug("启动，openPage=\(options.openPage?.rawValue ?? "nil")")
        if options.installHooks {
            for line in HookInstallModel.shared.installAllBlocking() {
                print(line)
            }
            exit(0)
        }
        SessionStore.shared.start()
        UsageStore.shared.start()
        // 断言随上一个进程死了，按落盘的状态接回来
        KeepAwake.shared.restore()
        // 上一轮要是被强杀，系统里还留着「合盖不休眠」；有免密规则就直接抹掉，没有就交给界面提示
        LidSleepBlocker.shared.checkResidue()
        let panelPage = options.openPage.flatMap { LaunchOptions.Page.panelPages.contains($0) ? $0 : nil }
        // 面板浮在所有窗口之上，不先收起来会盖住设置窗口的上半截；所有打开设置的入口都经过 show()
        SettingsWindowController.shared.willShow = { [weak self] in self?.notch?.close() }
        notch = NotchController(openOnLaunch: panelPage) {
            SettingsWindowController.shared.show()
        }
        if !pendingFiles.isEmpty {
            notch?.receiveFiles(pendingFiles)
            pendingFiles = []
        }
        if options.openPage == .settings {
            SettingsWindowController.shared.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 合盖不休眠是系统级的持久设置，不在这儿收掉的话，退出 Tally 之后机器再也不休眠
        LidSleepBlocker.shared.disable()
        UsageStore.shared.flushScanCaches()
    }

    /// `open -a Tally <文件…>`：放进文件架。Info.plist 不声明文档类型，访达的「打开方式」里没有 Tally，明说 `-a Tally` 才进来。
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        if let notch {
            notch.receiveFiles(files)
        } else {
            pendingFiles += files
        }
    }

    /// 点 Dock 图标（设置窗口开着时才有）把设置窗口叫回来。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { SettingsWindowController.shared.show() }
        return true
    }
}
