import AppKit
import Foundation
import Observation
import QuickLookThumbnailing

/// 文件架上的一件：文件在 `files/<id>/<name>`，缩略图在 `thumbs/<id>.png`，都在磁盘上；内存里只有这几个字段。
struct ShelfItem: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let size: Int64
    /// 毫秒时间戳。
    let addedAt: Double
    /// 拖进来时的原路径，「剪切」靠它把来源文件也收走。老索引里没有这个键，解出来是 nil，那就只收架上这份。
    let source: String?
}

/// 文件架：拖到刘海上的文件复制一份暂存，可以拖出去、AirDrop、打开，3 天后自动清理。
///
/// 交互形态照 NotchDrop（MIT），实现是重写的：它把缩略图当 PNG Data 常驻内存并塞进 JSON、启动即解码全部条目、
/// 常驻全局鼠标监视器；这里索引只有几个字段，缩略图落盘、只在这页可见时读进内存，关掉开关什么都不留。
@MainActor
@Observable
final class ShelfStore {

    static let shared = ShelfStore()

    /// 暂存多久。
    static let retention: TimeInterval = 3 * 24 * 3600

    let directory: URL
    private(set) var items: [ShelfItem] = []
    /// 只在这页可见时有内容。
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var enabled = false
    private var visible = false

    init(directory: URL = PreferencesStore.directory.appendingPathComponent("shelf")) {
        self.directory = directory
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var filesDirectory: URL { directory.appendingPathComponent("files") }
    private var thumbsDirectory: URL { directory.appendingPathComponent("thumbs") }

    func fileURL(_ item: ShelfItem) -> URL {
        filesDirectory.appendingPathComponent(item.id).appendingPathComponent(item.name)
    }

    private func thumbURL(_ item: ShelfItem) -> URL {
        thumbsDirectory.appendingPathComponent(item.id + ".png")
    }

    // MARK: 起停

    /// 开：读索引、清过期；关：内存全放掉，磁盘上的文件不动（再开还在）。
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            try? FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: thumbsDirectory, withIntermediateDirectories: true)
            items = (try? JSONDecoder().decode([ShelfItem].self, from: Data(contentsOf: indexURL))) ?? []
            purgeExpired(now: Date())
        } else {
            items = []
            thumbnails = [:]
            visible = false
        }
    }

    /// 这页可见：把缩略图读进内存；不可见就放掉。
    func start() {
        visible = true
        purgeExpired(now: Date())
        for item in items where thumbnails[item.id] == nil {
            thumbnails[item.id] = NSImage(contentsOf: thumbURL(item))
        }
    }

    func stop() {
        visible = false
        thumbnails = [:]
    }

    /// 超过保留期的算过期。
    nonisolated static func expired(_ items: [ShelfItem], now: Date) -> [ShelfItem] {
        items.filter { now.timeIntervalSince1970 * 1000 - $0.addedAt > retention * 1000 }
    }

    private func purgeExpired(now: Date) {
        let gone = Self.expired(items, now: now)
        guard !gone.isEmpty else { return }
        for item in gone { deleteFiles(of: item) }
        items.removeAll { gone.contains($0) }
        save()
    }

    // MARK: 增删

    /// 每个文件复制进自己的目录（同名也不冲突），复制在后台，缩略图用 QuickLook 生成落盘。
    func add(urls: [URL]) async {
        guard enabled else { return }
        for url in urls {
            let item = ShelfItem(
                id: UUID().uuidString,
                name: url.lastPathComponent,
                size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
                addedAt: Date().timeIntervalSince1970 * 1000,
                source: url.path
            )
            let destination = fileURL(item)
            let thumb = thumbURL(item)
            let copied = await Task.detached(priority: .userInitiated) { () -> Bool in
                do {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: url, to: destination)
                } catch {
                    Log.error("文件架复制失败 \(url.lastPathComponent): \(error.localizedDescription)")
                    return false
                }
                if let image = await Self.thumbnail(for: destination), let png = Self.png(image) {
                    try? png.write(to: thumb, options: .atomic)
                }
                return true
            }.value
            guard copied, enabled else { continue }
            items.insert(item, at: 0)
            if visible { thumbnails[item.id] = NSImage(contentsOf: thumb) }
        }
        save()
    }

    /// 拖出去 / 移动时交出去的那个 URL：来源文件还在就交来源本身，不在了才退回架上这份副本。
    ///
    /// 为什么不是直接交架上那份：那样「剪切」就成了「把三天前的快照搬到目标，再把来源删掉」——
    /// 盘上凭空多一次整文件的复制（11 MB 也好 2 GB 也好），目标拿到的还是暂存那一刻的旧内容。
    /// 交来源就是访达自己做一次改名：同卷瞬时、内容是当前的，架上那份副本随后删掉即可，不用进废纸篓。
    func cutURL(_ item: ShelfItem) -> URL {
        if let source = item.source, FileManager.default.fileExists(atPath: source) {
            return URL(fileURLWithPath: source)
        }
        return fileURL(item)
    }

    /// 右键「移动到…」：把文件搬到选中的目录（搬的同样是来源本身），成功了再把架上那份清掉。
    /// 返回错误文案，nil 是成功。目标已经有同名文件就报错，什么都不删——这条路是给「我要确定地移走」用的，
    /// 不能默默覆盖。
    func moveTo(_ item: ShelfItem, directory: URL) -> String? {
        do {
            try FileManager.default.moveItem(at: cutURL(item), to: directory.appendingPathComponent(item.name))
        } catch {
            return error.localizedDescription
        }
        remove(item)
        return nil
    }

    func remove(_ item: ShelfItem) {
        deleteFiles(of: item)
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        save()
    }

    func clear() {
        for item in items { deleteFiles(of: item) }
        items = []
        thumbnails = [:]
        save()
    }

    private func deleteFiles(of item: ShelfItem) {
        try? FileManager.default.removeItem(at: fileURL(item).deletingLastPathComponent())
        try? FileManager.default.removeItem(at: thumbURL(item))
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: indexURL, options: .atomic)
        } catch {
            Log.error("文件架索引写入失败: \(error.localizedDescription)")
        }
    }

    // MARK: 缩略图与分享

    /// QuickLook 生成不了（没有预览器的类型）就用文件图标。
    nonisolated private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: 2, representationTypes: .thumbnail)
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    nonisolated private static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 系统 AirDrop 面板。面板不抢激活，先把 app 激活起来分享面板才出得来。
    static func airDrop(_ urls: [URL]) {
        guard !urls.isEmpty, let service = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }
}
