import SwiftUI

/// 会话列表页：按 updated_at 倒序，一行一个会话，点行跳回 Ghostty 窗口。
struct SessionsPage: View {
    var store = SessionStore.shared

    var body: some View {
        if store.sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.3))
                Text("没有在跑的会话")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.sessions) { session in
                        SessionRow(session: session)
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: SessionRecord
    var jump = SessionJump.shared
    @State private var hovered = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        let now = Date()
        let stale = session.isStale(now: now)
        Button(action: focus) {
            HStack(spacing: 8) {
                StateIcon(state: session.state, stale: stale)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(session.displayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .italic(stale)
                            .foregroundStyle(stale ? .white.opacity(0.45) : .white)
                            .lineLimit(1)
                        ProviderTag(session: session)
                    }
                    HStack(spacing: 6) {
                        Text(session.cwdLabel)
                        Text(Self.relative.localizedString(for: session.updatedDate, relativeTo: now))
                        if stale { Text("失联") }
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
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovered ? 0.10 : 0.05)))
        .onHover { hovered = $0 }
        .animation(.smooth(duration: 0.2), value: hovered)
    }

    private func focus() {
        // 脚本在后台跑，这里只等结果：第一次跳某个终端会弹自动化授权框，主线程不能卡在那儿
        Task { await jump.run(session) }
    }
}

/// 跳回会话的终端。点会话行和 ⌘1–⌘5 共用；失败的那句话按会话记在这儿，行里红字显示——
/// 记在行自己的 @State 里的话，⌘N 跳失败时面板里那一行根本不知道。
@MainActor
@Observable
final class SessionJump {
    static let shared = SessionJump()

    /// session_id → 上次跳失败的原因；跳成功就清掉。
    private(set) var failures: [String: String] = [:]

    /// 返回跳没跳成。
    @discardableResult
    func run(_ session: SessionRecord) async -> Bool {
        let failure = await Self.attempt(session)
        failures[session.sessionId] = failure
        return failure == nil
    }

    private static func attempt(_ session: SessionRecord) async -> String? {
        do {
            try await TerminalLocator.focus(session: session)
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

/// 状态图标：等审批橙、等输入黄、忙灰、完成绿、失联灰。
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
        case .done: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        if stale { return .gray }
        switch state {
        case .waitingPermission: return .orange
        case .waitingInput: return .yellow
        case .running: return .gray
        case .done: return .green
        }
    }
}
