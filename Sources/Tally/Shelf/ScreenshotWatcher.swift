import Foundation
import Observation
import UniformTypeIdentifiers

/// 新截图自动放进文件架：盯着截图文件夹，新出现的文件带 `kMDItemIsScreenCapture` 扩展属性才算截图——
/// 不看文件名，文件名随系统语言和用户设置变。认出来交给控制器，走和 `open -a Tally <文件>` 同一条路。
///
/// 文件夹必须是用户在选择面板里点过的：桌面、文稿、下载受隐私保护，点选那一下系统把授权记在那个目录上（`com.apple.macl`），
/// 之后跨重启都能读，不弹框；没点过就读不到，这时把原因亮在设置里，不默默失效。
@MainActor
@Observable
final class ScreenshotWatcher {

    static let shared = ScreenshotWatcher()

    /// 新截图到了，控制器接去放进文件架。
    var onScreenshots: (([URL]) -> Void)?
    /// 读不了文件夹时的原因，设置页显示；正常为 nil。
    private(set) var problem: String?
    private(set) var folder: URL?

    /// 盯的是系统截图位置就要认截图标记（桌面上还有别的文件）；是截图工具自己的文件夹就不认，新图片都算。
    private var requireMark = true
    private var source: DispatchSourceFileSystemObject?
    /// 已经见过的文件（按 inode 记）：开始盯之前就在的不算新；在访达里改个名还是同一个文件，不重复放。
    private var seen: Set<UInt64> = []
    private var pendingScan: DispatchWorkItem?
    /// 文件夹不见了或读不了之后隔多久再试；测试改短。
    var retryInterval: TimeInterval = 30
    private var retry: DispatchWorkItem?

    /// 系统截图存到哪儿：`com.apple.screencapture` 的 `location`，没设过是桌面。
    nonisolated static func systemLocation() -> URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// 幂等：同一个文件夹已经在盯就不重来（设置每次变化都会调到这里，重来会把这段时间里到的截图记成「见过」）。
    func start(folder: URL) {
        guard folder != self.folder || source == nil else { return }
        stop()
        guard let listing = Self.listing(folder) else {
            problem = "读不了 \(folder.path)：文件夹回来了会自动接着盯；是没授权的话到设置「文件架」里重新选一次"
            Log.error("截图文件夹读不了: \(folder.path)")
            scheduleRetry(folder)
            return
        }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            problem = "盯不住 \(folder.path)（open 失败 errno \(errno)）"
            scheduleRetry(folder)
            return
        }
        problem = nil
        self.folder = folder
        requireMark = Self.isSystemLocation(folder)
        seen = Set(listing.map(\.inode))
        // 盯的是目录的文件描述符，不是路径：目录被删、被挪走（iCloud 桌面同步、外接盘拔掉）之后这个描述符就再也不来事件，
        // 所以 .delete / .rename 也要收，收到就停下并把原因亮出来
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let events = source?.data else { return }
            MainActor.assumeIsolated { self?.handle(events) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        pendingScan?.cancel()
        pendingScan = nil
        retry?.cancel()
        retry = nil
        folder = nil
        seen = []
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        guard events.contains(.delete) || events.contains(.rename) else { return scheduleScan() }
        guard let target = folder else { return }
        stop()
        problem = "截图文件夹 \(target.path) 不见了：它回来了会自动接着盯，一直不回来就到设置「文件架」里换一个"
        Log.error("截图文件夹不见了: \(target.path)")
        scheduleRetry(target)
    }

    /// 文件夹不见了或读不了：隔一会儿再试。截图工具放在临时目录里的文件夹会被系统清掉，下次存图又建回来；
    /// 不重试的话就一直停着，只剩设置里一行没人看的红字。关掉功能或换文件夹时 `stop()` 会把它撤掉。
    private func scheduleRetry(_ target: URL) {
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.start(folder: target) }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval, execute: work)
    }

    /// 一次截图会连着触发好几次目录变化，攒半秒再扫。
    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scan() {
        guard let folder else { return }
        // 开始时读得了、后来读不了（隐私设置里把授权收回了）：不能默默不收，原因亮到设置里
        guard let listing = Self.listing(folder) else {
            problem = "读不了 \(folder.path)：到设置「文件架」里重新选一次这个文件夹"
            Log.error("截图文件夹读不了: \(folder.path)")
            return
        }
        problem = nil
        let fresh = listing.filter { !seen.contains($0.inode) }
        seen.formUnion(fresh.map(\.inode))
        let shots = fresh.map(\.url).filter { Self.accepts($0, requireMark: requireMark) }
        if !shots.isEmpty { onScreenshots?(shots) }
    }

    /// 文件夹里的非隐藏文件与 inode；读不了（没授权、不存在）返回 nil。
    nonisolated static func listing(_ folder: URL) -> [(url: URL, inode: UInt64)]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return nil }
        return urls.compactMap { url in
            guard let inode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? UInt64 else { return nil }
            return (url, inode)
        }
    }

    /// 粘贴进来的路径：去掉空白和包着的引号、展开 ~，得是存在的文件夹。
    nonisolated static func folder(fromTyped text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
        return isDirectory(url) ? url : nil
    }

    private nonisolated static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }

    /// 系统截图位置（多半是桌面，别的文件也往这儿放）要认截图标记；用户另选的文件夹（Lens、Shottr 这类工具的保存目录）
    /// 本来就只进截图，而这些工具多数不写标记（Lens 实测一个都没有），新出现的图片都算。
    nonisolated static func accepts(_ url: URL, requireMark: Bool) -> Bool {
        requireMark ? isScreenCapture(url) : isImage(url)
    }

    nonisolated static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    nonisolated static func isSystemLocation(_ folder: URL, system: URL = systemLocation()) -> Bool {
        folder.standardizedFileURL.resolvingSymlinksInPath().path == system.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 系统截图快捷键（存到文件的 ⌘⇧3 / ⌘⇧4、拷到剪贴板的两个、⌘⇧5）是不是全关了：全关的话系统截图位置不会再有新截图，
    /// 用户多半在用别的截图工具，得在设置里说一声。偏好里没写的键是默认开着的。
    nonisolated static func systemShortcutsDisabled(_ hotkeys: [String: Any]?) -> Bool {
        guard let hotkeys else { return false }
        let entries = ["28", "29", "30", "31", "184"].map { hotkeys[$0] as? [String: Any] }
        return entries.allSatisfy { entry in
            guard let entry, let enabled = entry["enabled"] as? NSNumber else { return false }
            return !enabled.boolValue
        }
    }

    nonisolated static var systemShortcutsDisabledNow: Bool {
        systemShortcutsDisabled(UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"))
    }

    /// 系统截图（和 CleanShot 这类）会给文件写 `com.apple.metadata:kMDItemIsScreenCapture` = true（二进制 plist），复制后也还在。
    /// 直接读扩展属性，不等 Spotlight 建完索引。
    nonisolated static func isScreenCapture(_ url: URL) -> Bool {
        let name = "com.apple.metadata:kMDItemIsScreenCapture"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0 else { return false }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, 0) }
        guard read == size, let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return false }
        return (value as? NSNumber)?.boolValue == true
    }
}
