import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 「文件架」页：拖进来的文件按时间倒序排成网格，点开、拖出、右键 AirDrop / 删除。拖放本身挂在面板根视图上（任何一页都接）。
struct ShelfPage: View {
    var store = ShelfStore.shared

    var body: some View {
        Card {
            HStack(spacing: 6) {
                Text(store.items.isEmpty
                     ? "把文件拖到刘海上就会放到这里，保留 \(RetentionFormat.text(PreferencesStore.shared.prefs.shelfFileRetentionMinutes))"
                     : "点开、拖出去；按住 ⌘ 拖出去是剪切，来源文件一起走")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: 8)
                if !store.items.isEmpty {
                    HeaderButton(symbol: "wifi.circle", help: "AirDrop 全部") {
                        ShelfStore.airDrop(store.items.map(store.fileURL))
                    }
                    HeaderButton(symbol: "trash", help: "清空文件架") { store.clear() }
                }
            }
            if store.items.isEmpty {
                // 拖放靶子给足高度：空着时只有一条细框，页矮得像残页，也不好拖中
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .frame(height: 160)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.system(size: 26))
                                .foregroundStyle(.white.opacity(0.3))
                            Text("拖文件到这里")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                    ForEach(store.items) { item in
                        ShelfItemView(item: item, store: store)
                    }
                }
                .frame(minHeight: 160, alignment: .top)
            }
        }
    }
}

/// 一件：缩略图 + 名字 + 大小；悬停出删除叉，点开，按住拖出去是文件本身。
private struct ShelfItemView: View {
    let item: ShelfItem
    var store: ShelfStore
    @State private var hovered = false
    @State private var box = ShelfDragBox()

    var body: some View {
        let url = store.fileURL(item)
        VStack(spacing: 4) {
            Group {
                if let image = store.thumbnails[item.id] {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(item.name)
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ByteFormat.string(UInt64(max(0, item.size))))
                .font(.metric(9, .regular))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovered ? 0.10 : 0.04)))
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button { store.remove(item) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .buttonStyle(.plain)
                .padding(3)
            }
        }
        .contentShape(Rectangle())
        // 拖出去交的是来源文件本身（来源没了才退回架上这份），所以 .move 之后只剩「把架上这份清掉」
        .background(ShelfDragSource(url: store.cutURL(item), box: box) { store.remove(item) })
        .onHover { hovered = $0 }
        .onTapGesture { NSWorkspace.shared.open(url) }
        // 拖放会话由 AppKit 起（见 ShelfDragSource），这里只负责「手按着动了」这一下；
        // simultaneous 是为了不把点开那一下的点击手势挤掉
        .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { _ in box.view?.begin() })
        .contextMenu {
            Button("打开") { NSWorkspace.shared.open(url) }
            Button("AirDrop") { ShelfStore.airDrop([url]) }
            Button("移动到…") { moveTo() }
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("删除") { store.remove(item) }
        }
        .help(item.name)
    }

    /// 右键「移动到…」：选目录 → 搬过去 → 来源进废纸篓。面板不抢激活，不先 activate 系统面板出不来。
    private func moveTo() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "移动到这里"
        panel.message = "把「\(item.name)」移到哪个目录"
        // 面板 level 比模态窗口高，不让路的话选目录面板会被它盖住
        guard NotchPanel.steppingAside({ panel.runModal() }) == .OK, let directory = panel.url else { return }
        guard let message = store.moveTo(item, directory: directory) else { return }
        let alert = NSAlert()
        alert.messageText = "没能移动 \(item.name)"
        alert.informativeText = message
        NotchPanel.steppingAside { alert.runModal() }
    }
}

/// 拖出去的拖源。SwiftUI 的 `.onDrag` 只交出一个 item provider，拿不到拖放结束时目标执行的是 copy 还是 move，
/// 而「按 ⌘ 拖出去 = 剪切」必须等结果出来才敢动文件。所以自己起 AppKit 的拖放会话：这个 NSView 待在
/// `.background` 里且不参与命中测试，点开、悬停、右键照旧归 SwiftUI，只借它当 `NSDraggingSource`。
private struct ShelfDragSource: NSViewRepresentable {
    let url: URL
    let box: ShelfDragBox
    let onMoved: () -> Void

    func makeNSView(context: Context) -> ShelfDragSourceView {
        let view = ShelfDragSourceView()
        box.view = view
        return view
    }

    func updateNSView(_ view: ShelfDragSourceView, context: Context) {
        box.view = view
        view.url = url
        view.onMoved = onMoved
    }
}

/// SwiftUI 那边要能叫到 NSView 上的 `begin()`，用一个盒子把引用递出来。
private final class ShelfDragBox {
    weak var view: ShelfDragSourceView?
}

private final class ShelfDragSourceView: NSView, NSDraggingSource {
    var url: URL?
    var onMoved: (() -> Void)?
    private var dragging = false

    /// 背景视图不吃事件：点击、悬停、右键全都照旧落到上面的 SwiftUI 视图上。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 两种都允许，按不按 ⌘ 由访达定；只给 `.move` 的话不按 ⌘ 也会搬走，太吓人。
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        Log.debug("文件架拖出结束 operation=\(operation.rawValue)")
        guard operation == .move else { return }
        onMoved?()
    }

    /// 会话跑起来之后 AppKit 自己接管鼠标，SwiftUI 的手势收不到收尾，所以「正在拖」记在这儿。
    func begin() {
        guard !dragging, let url else { return }
        // beginDraggingSession 要一个鼠标事件，手势回调里的 currentEvent 正是那一次拖动；别的类型给进去会炸
        guard let event = NSApp.currentEvent, event.type == .leftMouseDragged || event.type == .leftMouseDown else {
            Log.debug("文件架拖出没起来，currentEvent=\(NSApp.currentEvent.map { String(describing: $0.type) } ?? "nil")")
            return
        }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(NSRect(x: bounds.midX - 22, y: bounds.midY - 22, width: 44, height: 44),
                              contents: NSWorkspace.shared.icon(forFile: url.path))
        dragging = true
        beginDraggingSession(with: [item], event: event, source: self)
    }
}

/// 拖放落到面板任何地方：把文件 URL 从 item provider 里取出来交给文件架。
enum ShelfDrop {
    static let types: [UTType] = [.fileURL]

    static func handle(_ providers: [NSItemProvider]) -> Bool {
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !candidates.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in candidates {
                if let url = await load(provider) { urls.append(url) }
            }
            await ShelfStore.shared.add(urls: urls)
        }
        return true
    }

    private static func load(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
