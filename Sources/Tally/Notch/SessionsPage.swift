import SwiftUI

/// 会话列表：分「等你 / 在跑 / 最近」三组，一行一个会话，点行跳回它的终端。
/// 已关闭的在会话卡片的另一页（`showingClosed`）：只列已关闭的，点行尾「接着聊」才开新终端。
struct SessionsPage: View {
    var store = SessionStore.shared
    var jump = SessionJump.shared
    /// 翻到「已关闭」那一页：由 AI 页会话卡片标题行的切换按钮决定。
    var showingClosed = false

    var body: some View {
        let now = Date()
        let rows = showingClosed
            ? SessionRecord.displayOrder(store.sessions, now: now).filter { $0.state == .ended }
            : SessionRecord.shortcutOrder(store.sessions, now: now)
        if rows.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: showingClosed ? "clock.arrow.circlepath" : "terminal")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.3))
                Text(showingClosed ? "没有已关闭的会话" : "没有在跑的会话")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                        if !showingClosed, index == 0 || rows[index - 1].group(now: now) != session.group(now: now) {
                            GroupHeader(group: session.group(now: now), first: index == 0)
                        }
                        // ⌘N 按没关闭的会话的显示顺序数，所以编号就是行号；已关闭那一页没有键
                        SessionRow(session: session, now: now,
                                   shortcut: !showingClosed && jump.shortcutHints ? PanelKey.sessionShortcutLabel(index) : nil)
                    }
                }
            }
        }
    }
}

/// 组头：一行灰色小字。
private struct GroupHeader: View {
    let group: SessionRecord.Group
    let first: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.leading, 6)
            .padding(.top, first ? 0 : 4)
    }

    private var title: String {
        switch group {
        case .waiting: return "等你"
        case .working: return "在跑"
        case .recent: return "最近"
        case .closed: return "已关闭"
        }
    }
}

struct SessionRow: View {
    let session: SessionRecord
    let now: Date
    /// 按住 ⌘ 时行尾显示的编号（⌘1…⌘9、⌘0），nil 不显示。
    let shortcut: String?
    var jump = SessionJump.shared
    @State private var hovered = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        if session.state == .ended {
            // 已关闭的行本身不可点：点下去会开新终端，只认行尾那颗「接着聊」
            content(stale: false, ended: true)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.05)))
        } else {
            Button(action: focus) {
                content(stale: session.isStale(now: now), ended: false)
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovered ? 0.10 : 0.05)))
            .onHover { hovered = $0 }
            .animation(.smooth(duration: 0.2), value: hovered)
        }
    }

    private func content(stale: Bool, ended: Bool) -> some View {
            HStack(spacing: 8) {
                StateIcon(state: session.state, stale: stale)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(session.displayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .italic(stale)
                            .foregroundStyle(stale || ended ? .white.opacity(0.45) : .white)
                            .lineLimit(1)
                        ProviderTag(session: session)
                        // tmux 里的会话点了先切 pane 再带外层终端，标出来免得以为跳错了地方
                        if session.term == "tmux" {
                            Text("tmux")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.14)))
                        }
                    }
                    HStack(spacing: 6) {
                        Text(session.cwdLabel)
                        Text(Self.relative.localizedString(for: session.updatedDate, relativeTo: now))
                        if stale { Text("失联") }
                        if session.state == .compacting { Text("压缩上下文中") }
                        if ended { Text("已关闭") }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let failure = jump.failures[session.sessionId] {
                    Text(failure)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.12)))
                }
                if ended {
                    Button(action: focus) {
                        Text("接着聊")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.14)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
    }

    private func focus() {
        // 脚本在后台跑，这里只等结果：第一次跳某个终端会弹自动化授权框，主线程不能卡在那儿
        Task { await jump.run(session) }
    }
}

/// 跳回会话的终端（已关闭的会话是在新终端里接着聊）。点会话行和 ⌘1–⌘9 / ⌘0 共用；失败的那句话按会话记在这儿，行里红字显示——
/// 记在行自己的 @State 里的话，⌘N 跳失败时面板里那一行根本不知道。
@MainActor
@Observable
final class SessionJump {
    static let shared = SessionJump()

    /// session_id → 上次跳失败的原因；跳成功就清掉。
    private(set) var failures: [String: String] = [:]
    /// 按住 ⌘ 时为真：前十行行尾显示 ⌘1…⌘9、⌘0。面板的键盘监视器写。
    var shortcutHints = false

    /// 返回跳没跳成。
    @discardableResult
    func run(_ session: SessionRecord) async -> Bool {
        let failure = await Self.attempt(session)
        failures[session.sessionId] = failure
        return failure == nil
    }

    private static func attempt(_ session: SessionRecord) async -> String? {
        // 演示模式的会话没有终端：跳过去会把别的真窗口叫到前台，接着聊会开新终端；当作跳成了，行里不出红字
        guard !DemoMode.isOn else { return nil }
        do {
            if session.state == .ended {
                try await SessionResume.run(session)
            } else {
                try await TerminalLocator.focus(session: session)
            }
            return nil
        } catch TerminalLocator.Failure.notFound {
            return "找不到窗口"
        } catch TerminalLocator.Failure.notRunning(let app) {
            return "\(app) 没在跑"
        } catch TerminalLocator.Failure.needsAutomationPermission(let app) {
            // 拒过之后系统不再弹框，只能自己把设置面板指出来
            TerminalLocator.openAutomationSettings()
            return "要允许 Tally 控制 \(app)"
        } catch {
            Log.error("定位失败: \(error)")
            return "定位失败"
        }
    }
}

/// 会话行的标签：提供方标志 + 模型短名（「Opus 5」「gpt-6-astra」），还不知道模型时写「Claude」「Codex」。
struct ProviderTag: View {
    let session: SessionRecord

    var body: some View {
        HStack(spacing: 3) {
            ProviderLogo(name: session.provider == "codex" ? "openai" : "claude", size: 9)
            Text(session.modelLabel ?? session.providerLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.14)))
    }
}

/// 状态图标：等审批橙、等输入黄、忙灰、压缩中青、完成绿、失联灰、已关闭灰。
struct StateIcon: View {
    let state: SessionRecord.State
    let stale: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(color)
            .frame(width: 16)
    }

    private var symbol: String {
        if stale { return "wifi.slash" }
        switch state {
        case .waitingPermission: return "exclamationmark.circle.fill"
        case .waitingInput: return "questionmark.circle.fill"
        case .running: return "circle.dotted"
        case .compacting: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .ended: return "arrow.uturn.backward.circle"
        }
    }

    private var color: Color {
        if stale { return .gray }
        switch state {
        case .waitingPermission: return .orange
        case .waitingInput: return .yellow
        case .running: return .gray
        case .compacting: return .cyan
        case .done: return .green
        case .ended: return .gray
        }
    }
}
