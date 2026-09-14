import Foundation
import Observation

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

    private var source: DispatchSourceFileSystemObject?
    /// 已经见过的文件（按 inode 记）：开始盯之前就在的不算新；在访达里改个名还是同一个文件，不重复放。
    private var seen: Set<UInt64> = []
    private var pendingScan: DispatchWorkItem?

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
            problem = "读不了 \(folder.path)：到设置「文件架」里重新选一次这个文件夹"
            Log.error("截图文件夹读不了: \(folder.path)")
            return
        }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            problem = "盯不住 \(folder.path)（open 失败 errno \(errno)）"
            return
        }
        problem = nil
        self.folder = folder
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
        folder = nil
        seen = []
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        guard events.contains(.delete) || events.contains(.rename) else { return scheduleScan() }
        let path = folder?.path ?? ""
        stop()
        problem = "截图文件夹 \(path) 被删了或挪走了：到设置「文件架」里重新选一次"
        Log.error("截图文件夹不见了: \(path)")
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
        let shots = fresh.map(\.url).filter(Self.isScreenCapture)
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
