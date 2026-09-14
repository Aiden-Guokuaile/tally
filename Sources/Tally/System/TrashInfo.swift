import Foundation

/// 废纸篓：只看 `~/.Trash`，不碰外接盘的 `.Trashes` 和 iCloud。
struct TrashInfo: Equatable {
    /// 顶层项数（隐藏文件不算）。
    var count: Int
    /// 递归的已分配大小。
    var bytes: UInt64

    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")

    /// 大废纸篓要走几秒，调用方放后台线程。
    static func scan(directory: URL = directory) -> TrashInfo {
        let manager = FileManager.default
        let items = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var bytes: UInt64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        for item in items {
            bytes += allocatedSize(of: item, keys: keys)
            if let enumerator = manager.enumerator(at: item, includingPropertiesForKeys: Array(keys)) {
                for case let child as URL in enumerator { bytes += allocatedSize(of: child, keys: keys) }
            }
        }
        return TrashInfo(count: items.count, bytes: bytes)
    }

    private static func allocatedSize(of url: URL, keys: Set<URLResourceKey>) -> UInt64 {
        guard let values = try? url.resourceValues(forKeys: keys), values.isDirectory != true else { return 0 }
        return UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    /// 逐个顶层项永久删除；某一项失败继续删下一项。返回删掉的项数与失败的项数。
    static func empty(directory: URL = directory) -> (removed: Int, failed: Int) {
        let manager = FileManager.default
        let items = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var removed = 0
        var failed = 0
        for item in items {
            do {
                try manager.removeItem(at: item)
                removed += 1
            } catch {
                failed += 1
                Log.error("清空废纸篓失败 \(item.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (removed, failed)
    }
}
