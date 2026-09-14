import AppKit
import Foundation
import Observation
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 放进文件架的是什么：保留时长分开算。
enum ShelfKind: String, Codable {
    /// 拖进来的、`open -a Tally` 放进来的。
    case file
    /// 「新截图自动放进文件架」收进来的。
    case screenshot
}

/// 文件架上的一件：文件在 `files/<id>/<name>`，缩略图在 `thumbs/<id>.png`，都在磁盘上；内存里只有这几个字段。
struct ShelfItem: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let size: Int64
    /// 毫秒时间戳。
    let addedAt: Double
    /// 拖进来时的原路径，「剪切」靠它把来源文件也收走。老索引里没有这个键，解出来是 nil，那就只收架上这份。
    let source: String?
    /// 老索引里没有这个键，解出来是 nil，按文件算。
    var kind: ShelfKind? = nil
}

/// 保留时长的文案与拆分：设置里按「数值 + 单位」填，存的是分钟。
enum RetentionFormat {
    enum Unit: Int, CaseIterable {
        case minutes = 1, hours = 60, days = 1440
        var label: String {
            switch self {
            case .minutes: return "分钟"
            case .hours: return "小时"
            case .days: return "天"
            }
        }
    }

    /// 能整除就用大单位：1440 →「1 天」，120 →「2 小时」，90 →「90 分钟」。
    static func split(_ minutes: Int) -> (amount: Int, unit: Unit) {
        for unit in [Unit.days, .hours] where minutes >= unit.rawValue && minutes % unit.rawValue == 0 {
            return (minutes / unit.rawValue, unit)
        }
        return (minutes, .minutes)
    }

    static func text(_ minutes: Int) -> String {
        let (amount, unit) = split(minutes)
        return "\(amount) \(unit.label)"
    }
}

/// 文件架：拖到刘海上的文件复制一份暂存，可以拖出去、AirDrop、打开；到了保留时间自动清理（文件和截图各设各的）。
///
/// 交互形态照 NotchDrop（MIT），实现是重写的：它把缩略图当 PNG Data 常驻内存并塞进 JSON、启动即解码全部条目、
/// 常驻全局鼠标监视器；这里索引只有几个字段，缩略图落盘、只在这页可见时读进内存，关掉开关什么都不留。
@MainActor
@Observable
final class ShelfStore {

    static let shared = DemoMode.isOn ? demo() : ShelfStore()

    /// 演示模式：目录指到不会被建出来的临时路径（真索引不读也不写）、保留时长拉满（录着录着不会被清掉）；
    /// 先把 enabled 置上，设置里的 setEnabled(true) 就在 guard 处返回，不去读索引。
    private static func demo() -> ShelfStore {
        let store = ShelfStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("tally-demo-shelf"),
                               retention: { (30 * 86400, 30 * 86400) })
        store.enabled = true
        store.items = DemoData.shelfItems(now: Date())
        return store
    }

    let directory: URL
    private(set) var items: [ShelfItem] = []
    /// 只在这页可见时有内容。
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var enabled = false
    private var visible = false
    /// 文件和截图各保留多久（秒），设置里调；测试注入。
    private let retention: () -> (file: TimeInterval, screenshot: TimeInterval)
    /// 到最早那一件的过期时刻就清：原来只在打开这页时清，过了时间的副本可能在磁盘上多躺好几天。
    @ObservationIgnored private var purgeTimer: Timer?

    init(directory: URL = PreferencesStore.directory.appendingPathComponent("shelf"),
         retention: (() -> (file: TimeInterval, screenshot: TimeInterval))? = nil) {
        self.directory = directory
        self.retention = retention ?? {
            let prefs = PreferencesStore.shared.prefs
            return (TimeInterval(prefs.shelfFileRetentionMinutes * 60), TimeInterval(prefs.shelfScreenshotRetentionMinutes * 60))
        }
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
            purgeTimer?.invalidate()
            purgeTimer = nil
            items = []
            thumbnails = [:]
            visible = false
        }
    }

    /// 设置里改了保留时长：按新时长马上清一次、重排定时器。幂等，控制器每次设置变化都调。
    func retentionChanged() {
        guard enabled else { return }
        purgeExpired(now: Date())
    }

    /// 这页可见：把缩略图读进内存；不可见就放掉。
    func start() {
        visible = true
        // 演示模式的条目在磁盘上没有文件和缩略图：按扩展名给系统类型图标，不然四件都是同一张白纸；stop() 会清掉，每次开页重给
        if DemoMode.isOn {
            for item in items {
                thumbnails[item.id] = NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.name as NSString).pathExtension) ?? .data)
            }
            return
        }
        purgeExpired(now: Date())
        for item in items where thumbnails[item.id] == nil {
            thumbnails[item.id] = NSImage(contentsOf: thumbURL(item))
        }
    }

    func stop() {
        visible = false
        thumbnails = [:]
    }

    /// 一件的过期时刻：截图按截图的时长，其余（含老索引里没标种类的）按文件的时长。
    nonisolated static func expiry(of item: ShelfItem, file: TimeInterval, screenshot: TimeInterval) -> Date {
        Date(timeIntervalSince1970: item.addedAt / 1000 + (item.kind == .screenshot ? screenshot : file))
    }

    /// 到了过期时刻的算过期。纯函数。
    nonisolated static func expired(_ items: [ShelfItem], now: Date, file: TimeInterval, screenshot: TimeInterval) -> [ShelfItem] {
        items.filter { expiry(of: $0, file: file, screenshot: screenshot) <= now }
    }

    /// 最早一件的过期时刻，定时器排到那儿；空的就不排。
    nonisolated static func nextExpiry(_ items: [ShelfItem], file: TimeInterval, screenshot: TimeInterval) -> Date? {
        items.map { expiry(of: $0, file: file, screenshot: screenshot) }.min()
    }

    private func purgeExpired(now: Date) {
        let limits = retention()
        let gone = Self.expired(items, now: now, file: limits.file, screenshot: limits.screenshot)
        if !gone.isEmpty {
            for item in gone { deleteFiles(of: item) }
            items.removeAll { gone.contains($0) }
            for item in gone { thumbnails[item.id] = nil }
            save()
        }
        schedulePurge()
    }

    /// 排到最早一件过期的那一刻；每次增删、清完、改时长都重排。多等 1 秒，免得差几毫秒没过期又空转一圈。
    /// 定时器故意挂在默认模式：拖文件、弹选择面板期间不触发，结束后补上——挂到 .common 的话，正往外拖的那件可能被当场删掉。
    private func schedulePurge() {
        purgeTimer?.invalidate()
        purgeTimer = nil
        let limits = retention()
        guard enabled, let next = Self.nextExpiry(items, file: limits.file, screenshot: limits.screenshot) else { return }
        purgeTimer = Timer.scheduledTimer(withTimeInterval: max(next.timeIntervalSinceNow, 0) + 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeExpired(now: Date()) }
        }
    }

    // MARK: 增删

    /// 每个文件复制进自己的目录（同名也不冲突），复制在后台，缩略图用 QuickLook 生成落盘。`kind` 决定保留多久。
    /// 演示模式不收：录屏时拖进来的是真文件。
    func add(urls: [URL], kind: ShelfKind = .file) async {
        guard enabled, !DemoMode.isOn else { return }
        for url in urls {
            let item = ShelfItem(
                id: UUID().uuidString,
                name: url.lastPathComponent,
                size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0,
                addedAt: Date().timeIntervalSince1970 * 1000,
                source: url.path,
                kind: kind
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
        schedulePurge()
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
        guard !DemoMode.isOn else { return nil }
        do {
            try FileManager.default.moveItem(at: cutURL(item), to: directory.appendingPathComponent(item.name))
        } catch {
            return error.localizedDescription
        }
        remove(item)
        return nil
    }

    /// 演示模式下删除、清空都不做：条目是编的，删了这一轮录屏就没东西可拍了。
    func remove(_ item: ShelfItem) {
        guard !DemoMode.isOn else { return }
        deleteFiles(of: item)
        items.removeAll { $0.id == item.id }
        thumbnails[item.id] = nil
        save()
        schedulePurge()
    }

    func clear() {
        guard !DemoMode.isOn else { return }
        for item in items { deleteFiles(of: item) }
        items = []
        thumbnails = [:]
        save()
        schedulePurge()
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
