import Foundation
import Observation

/// Tally 自己的设置，存 JSON。抄 Watchdog 的 Preferences 骨架。
///
/// 解码一律 `decodeIfPresent` 取默认值：以后加字段时，老文件缺键也能读。
struct Preferences: Codable, Equatable {
    /// 登录时自动启动。
    var launchAtLogin = false
    /// 用量页的四个提供方开关。
    var enableClaude = true
    var enableCodex = true
    var enableAntigravity = true
    var enableCursor = true
    /// 面板上次点开的页（rawValue），启动时回到它；`--open` 不写它。
    var lastPage = "ai"
    /// ⌥⇧T 全局快捷键。
    var hotKeyEnabled = true
    /// 下面六个是「功能开关」：关掉的功能不起监听、不占内存。
    /// 鼠标停在刘海上展开。
    var hoverToOpen = true
    /// 标题行的「保持唤醒」按钮。
    var keepAwakeButton = true
    /// 保持唤醒时屏幕也常亮（`caffeinate -d`）；关了只挡系统休眠，屏幕照常黑。
    var keepAwakeDisplay = true
    /// 保持唤醒当前开着；断言随进程死，落盘才能跨重装接回来。
    var keepAwakeActive = false
    /// 保持唤醒的到期时刻（Unix 秒），开着且不限时为 nil。
    var keepAwakeUntil: Double?
    /// 保持唤醒选的时长档（分钟），不限时或没开着为 nil；重启后右键菜单靠它把勾接回原来那档。
    var keepAwakeMinutes: Int?
    /// 自定义时长档（分钟），没设过是 nil；范围与步长见 `KeepAwake.clampCustom(_:)`。
    var keepAwakeCustomMinutes: Int?
    /// 接电、拔电、低电、充满时闭合态弹一下。
    var batteryPeek = true
    /// 提示条停留几秒：AI 会话类（等审批比它多留 `Peek.askExtra`）与电池类各一个，2 到 30 秒。
    var peekSessionSeconds = 5
    var peekBatterySeconds = 3
    /// 点会话提示条时做什么，取值见 `PeekTapAction`。默认跳回对应终端：提示条说的就是那个会话，点它就是要过去。
    var peekTapAction = PeekTapAction.terminal.rawValue
    /// 摄像头 / 麦克风被占用时标题行画点。
    var privacyDots = true
    /// 截屏与共享屏幕时隐藏面板。
    var hideFromCapture = false
    /// 「文件架」页：拖文件到刘海暂存。
    var shelfEnabled = true
    /// 面板展开时按 1–9 切到第 N 个页签。
    var pageNumberKeys = true
    /// 面板展开时按 ⌘1–⌘5 跳到 AI 页第 N 个会话的终端。只在面板展开时归面板，收起后浏览器、终端自己的 ⌘1–⌘5 照常。
    var sessionCommandKeys = true

    init() {}

    /// 提示条秒数夹在 2 到 30 之间。
    static func peekSeconds(_ value: Int) -> Int { min(max(value, 2), 30) }

    /// 只认面板页；老文件或手改成别的都回到 ai。
    static func panelPage(_ raw: String) -> String {
        LaunchOptions.Page.panelPages.map(\.rawValue).contains(raw) ? raw : "ai"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        enableClaude = try c.decodeIfPresent(Bool.self, forKey: .enableClaude) ?? d.enableClaude
        enableCodex = try c.decodeIfPresent(Bool.self, forKey: .enableCodex) ?? d.enableCodex
        enableAntigravity = try c.decodeIfPresent(Bool.self, forKey: .enableAntigravity) ?? d.enableAntigravity
        enableCursor = try c.decodeIfPresent(Bool.self, forKey: .enableCursor) ?? d.enableCursor
        lastPage = Self.panelPage(try c.decodeIfPresent(String.self, forKey: .lastPage) ?? d.lastPage)
        hotKeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotKeyEnabled) ?? d.hotKeyEnabled
        hoverToOpen = try c.decodeIfPresent(Bool.self, forKey: .hoverToOpen) ?? d.hoverToOpen
        keepAwakeButton = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeButton) ?? d.keepAwakeButton
        keepAwakeDisplay = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeDisplay) ?? d.keepAwakeDisplay
        keepAwakeActive = try c.decodeIfPresent(Bool.self, forKey: .keepAwakeActive) ?? d.keepAwakeActive
        keepAwakeUntil = try c.decodeIfPresent(Double.self, forKey: .keepAwakeUntil)
        keepAwakeMinutes = try c.decodeIfPresent(Int.self, forKey: .keepAwakeMinutes)
        keepAwakeCustomMinutes = try c.decodeIfPresent(Int.self, forKey: .keepAwakeCustomMinutes)
        batteryPeek = try c.decodeIfPresent(Bool.self, forKey: .batteryPeek) ?? d.batteryPeek
        // 手改成离谱的秒数不至于让提示条永远不收 / 一闪而过
        peekSessionSeconds = Self.peekSeconds(try c.decodeIfPresent(Int.self, forKey: .peekSessionSeconds) ?? d.peekSessionSeconds)
        peekBatterySeconds = Self.peekSeconds(try c.decodeIfPresent(Int.self, forKey: .peekBatterySeconds) ?? d.peekBatterySeconds)
        peekTapAction = PeekTapAction.parse(try c.decodeIfPresent(String.self, forKey: .peekTapAction) ?? d.peekTapAction).rawValue
        privacyDots = try c.decodeIfPresent(Bool.self, forKey: .privacyDots) ?? d.privacyDots
        hideFromCapture = try c.decodeIfPresent(Bool.self, forKey: .hideFromCapture) ?? d.hideFromCapture
        shelfEnabled = try c.decodeIfPresent(Bool.self, forKey: .shelfEnabled) ?? d.shelfEnabled
        pageNumberKeys = try c.decodeIfPresent(Bool.self, forKey: .pageNumberKeys) ?? d.pageNumberKeys
        sessionCommandKeys = try c.decodeIfPresent(Bool.self, forKey: .sessionCommandKeys) ?? d.sessionCommandKeys
    }
}

/// 设置的唯一持有者。改 `prefs` 就落盘。
@MainActor
@Observable
final class PreferencesStore {

    static let shared = PreferencesStore()

    /// Tally 的数据目录，会话状态文件也在这下面。
    nonisolated static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Tally")

    var prefs: Preferences {
        didSet {
            save()
            onChange?()
        }
    }

    /// 每次改完设置都调一次，控制器据此起停各功能；幂等，页签切换写 lastPage 也会触发，无妨。
    var onChange: (() -> Void)?

    /// 最近一次落盘失败的原因，设置页红字显示；成功后清空。内存里的值已经改了，重启会回到磁盘上的旧值。
    private(set) var saveError: String?

    private let url: URL

    init(url: URL = PreferencesStore.directory.appendingPathComponent("preferences.json")) {
        self.url = url
        prefs = Preferences()
        // 第一次启动没有文件是正常的；有文件读不出来才值得记一笔
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            prefs = try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
        } catch {
            Log.error("设置读取失败，按默认值: \(url.path) \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(prefs).write(to: url, options: .atomic)
            saveError = nil
        } catch {
            saveError = "设置没能写进 \(url.lastPathComponent)：\(error.localizedDescription)"
            Log.error("设置写入失败: \(error.localizedDescription)")
        }
    }
}
