import AppKit
import SwiftUI

/// 设置是普通窗口，不挤在刘海里。版式照 Atoll / 系统设置：左边侧栏分组，右边分组表单。
///
/// app 是附件型（LSUIElement），窗口要能接键盘和 Toggle 点击就得临时切成常规应用；
/// 关窗再切回去，Dock 图标随之消失。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tally 设置"
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsWindowView())
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    /// 打开前先做的事：AppDelegate 接上「收起刘海面板」——面板浮在所有窗口之上，展开着会盖住设置窗口。
    /// 放在这里而不是某个入口上：设置窗口已经是 key 时 ⌘, 走主菜单的「设置…」，不经过面板，
    /// 原来只有面板入口先收面板，那条路上面板就一直挡在设置窗口前面。
    var willShow: (() -> Void)?

    func show() {
        // 演示模式不开：里面是真的 hook 心跳、凭据状态和路径
        guard !DemoMode.isOn else { return }
        willShow?()
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// 侧栏的七项：前两项和最后一项不带组标题（系统设置的做法），中间按「功能」「数据」分组。
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, panel, alerts, shelf, hooks, usage, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .panel: return "面板"
        case .alerts: return "提示"
        case .shelf: return "文件架"
        case .hooks: return "hook"
        case .usage: return "用量"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .panel: return "rectangle.topthird.inset.filled"
        case .alerts: return "bell.badge.fill"
        case .shelf: return "tray.full.fill"
        case .hooks: return "link"
        case .usage: return "chart.bar.fill"
        case .about: return "info"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .panel: return .blue
        case .alerts: return .orange
        case .shelf: return .teal
        case .hooks: return .purple
        case .usage: return .green
        case .about: return .secondary
        }
    }

    /// 侧栏分组：标题为 nil 的组不画组头。
    static let groups: [(title: String?, sections: [SettingsSection])] = [
        (nil, [.general, .panel]),
        ("功能", [.alerts, .shelf]),
        ("数据", [.hooks, .usage]),
        (nil, [.about]),
    ]
}

/// 窗口内容：侧栏 + 当前项的表单。
struct SettingsWindowView: View {
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Array(SettingsSection.groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group.sections) { section in
                            NavigationLink(value: section) { SidebarRow(section: section) }
                        }
                    } header: {
                        if let title = group.title { Text(title) }
                    }
                }
            }
            .listStyle(.sidebar)
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            detail
                .navigationTitle(selection.title)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .formStyle(.grouped)
        .frame(minWidth: 700, minHeight: 480)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettings()
        case .panel: PanelSettings()
        case .alerts: AlertSettings()
        case .shelf: ShelfSettings()
        case .hooks: HookSettings()
        case .usage: UsageSettings()
        case .about: HelpPage()
        }
    }
}

/// 侧栏一行：系统设置那种带渐变底的圆角小方块图标 + 名字。
private struct SidebarRow: View {
    let section: SettingsSection

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(LinearGradient(colors: [section.tint, section.tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: section.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            Text(section.title)
        }
        .padding(.vertical, 2)
    }
}
