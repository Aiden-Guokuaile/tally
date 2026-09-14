import AppKit
import SwiftUI

/// 「应用」页：在跑的 app，按内存降序，不带卡片标题（页签已经说明了是什么）；Dock 里看不见的名字后面带一个「眼睛划掉」图标。点行打开，右键退出，悬停高亮。
struct AppsPage: View {
    var store = RunningAppsStore.shared
    @State private var hovered: pid_t?
    private static let placeholder = NSWorkspace.shared.icon(for: .applicationBundle)

    var body: some View {
        if store.apps.isEmpty {
            Text("没有在跑的 app")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            Card {
                ForEach(store.apps) { app in
                    Button {
                        store.open(app)
                    } label: {
                        HStack(spacing: 8) {
                            // 图标从缓存拿；还没取到的先画个通用 app 图标占位
                            Image(nsImage: store.icons[app.id] ?? Self.placeholder)
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(app.name)
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if app.isHidden {
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .help("Dock 里看不见")
                            }
                            Spacer(minLength: 8)
                            Text(app.memory.map(ByteFormat.string) ?? "—")
                                .font(.metric(11, .medium))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovered == app.id ? 0.10 : 0)))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 ? app.id : (hovered == app.id ? nil : hovered) }
                    .contextMenu {
                        Button("在访达中显示") { store.reveal(app) }
                        Button("退出 \(app.name)") { store.quit(app) }
                    }
                }
            }
        }
    }
}
