import CoreServices
import Foundation
import Observation

/// 「截一张图找文件夹」：盯着家目录和本用户的临时目录 30 秒，谁先新建了一张图片，那张图所在的文件夹多半就是截图工具的保存位置。
///
/// 不认具体是哪个截图软件：Lens 存在 `$TMPDIR/Lens`，别的工具各有各的地方，用户自己也改得了；而临时目录藏在 /var/folders 下，
/// 选择面板点不进去。所以只看「截图那一刻新出现的图片落在哪」，找到了给用户确认，不自动套用——那 30 秒里别的程序也可能写图片。
@MainActor
@Observable
final class ScreenshotFolderFinder {

    static let shared = ScreenshotFolderFinder()

    static let timeout: TimeInterval = 30

    enum Status: Equatable {
        case idle
        case waiting
        /// 找到的文件夹和让它露馅的那张图的文件名。
        case found(URL, file: String)
        case timedOut
        case failed
    }

    private(set) var status: Status = .idle
    @ObservationIgnored private var stream: FSEventStreamRef?
    @ObservationIgnored private var timer: Timer?

    func start() {
        stop()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // `$TMPDIR` 的上一层（/var/folders/xx/yyy），T 和 C 都在里面；FSEvents 报的是 /private/var 开头的真实路径
        let temporaryRoot = FileManager.default.temporaryDirectory.deletingLastPathComponent().resolvingSymlinksInPath().path
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let finder = Unmanaged<ScreenshotFolderFinder>.fromOpaque(info).takeUnretainedValue()
            let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
            let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
            MainActor.assumeIsolated { finder.handle(paths: list, flags: flagList) }
        }
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [home, temporaryRoot] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, options)
        else {
            Log.error("截图文件夹：FSEvents 流建不起来")
            status = .failed
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        status = .waiting
        timer = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.status == .waiting else { return }
                self.stopStream()
                self.status = .timedOut
            }
        }
    }

    /// 取消或用完：停掉监听，结果清回空闲。
    func stop() {
        stopStream()
        status = .idle
    }

    private func stopStream() {
        timer?.invalidate()
        timer = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard status == .waiting else { return }
        let excluded = [PreferencesStore.directory.path, PreferencesStore.directory.resolvingSymlinksInPath().path]
        for (path, flag) in zip(paths, flags) {
            // 改名事件新旧两个路径都会报，只认还在的那个
            guard let folder = Self.folder(forEventPath: path, flags: flag, excluding: excluded),
                  FileManager.default.fileExists(atPath: path)
            else { continue }
            stopStream()
            status = .found(folder, file: URL(fileURLWithPath: path).lastPathComponent)
            return
        }
    }

    /// 一个 FSEvents 事件算不算「截图工具刚存了一张图」：新建或改名进来的文件、是图片、路径里没有隐藏目录（废纸篓、各种 .cache）、
    /// 不在缓存目录（浏览器一直在写缩略图）和 Tally 自己的目录里。算的话返回它所在的文件夹。纯函数。
    nonisolated static func folder(forEventPath path: String, flags: FSEventStreamEventFlags, excluding excluded: [String]) -> URL? {
        let isFile = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0
        let appeared = flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
        guard isFile, appeared else { return nil }
        let url = URL(fileURLWithPath: path)
        guard ScreenshotWatcher.isImage(url),
              !url.pathComponents.dropLast().contains(where: { $0.hasPrefix(".") }),
              !url.lastPathComponent.hasPrefix("."),
              !path.contains("/Library/Caches/"),
              !excluded.contains(where: { !$0.isEmpty && path.hasPrefix($0) })
        else { return nil }
        return url.deletingLastPathComponent()
    }
}
