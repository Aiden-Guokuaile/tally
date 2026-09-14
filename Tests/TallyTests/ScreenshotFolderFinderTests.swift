import CoreServices
import XCTest
@testable import Tally

/// 「截一张图找文件夹」的事件筛选（docs/shelf.md「截图自动放进来」）。不认具体截图软件，只看新图片落在哪。
final class ScreenshotFolderFinderTests: XCTestCase {

    private let created = FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
    private let renamed = FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemIsFile)
    private let excluded = ["/Users/x/Library/Application Support/Tally"]

    private func folder(_ path: String, _ flags: FSEventStreamEventFlags) -> String? {
        ScreenshotFolderFinder.folder(forEventPath: path, flags: flags, excluding: excluded)?.path
    }

    func testNewImagesPointAtTheirFolder() {
        XCTAssertEqual(folder("/private/var/folders/l_/abc/T/Lens/Lens-20260914-153724-715.png", created), "/private/var/folders/l_/abc/T/Lens",
                       "临时目录里的也认：Lens 这类存在那儿")
        XCTAssertEqual(folder("/Users/x/Pictures/Shots/截屏 2026-09-14.JPG", renamed), "/Users/x/Pictures/Shots", "改名进来的、大写扩展名也认")
    }

    /// 真跑一次 FSEvents：在临时目录里新建一张图，找到的就是它所在的文件夹（FSEvents 报的是 /private/var 开头的真实路径）。
    @MainActor
    func testFindsTheFolderOfANewImage() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-finder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let finder = ScreenshotFolderFinder()
        defer { finder.stop() }
        finder.start()
        XCTAssertEqual(finder.status, .waiting)
        try await Task.sleep(nanoseconds: 300_000_000)
        try Data("png".utf8).write(to: dir.appendingPathComponent("shot.png"))
        for _ in 0..<30 where finder.status == .waiting {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard case .found(let folder, let file) = finder.status else { return XCTFail("没找到：\(finder.status)") }
        XCTAssertEqual(folder.resolvingSymlinksInPath().path, dir.resolvingSymlinksInPath().path)
        XCTAssertEqual(file, "shot.png")
    }

    func testNoiseIsIgnored() {
        let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile)
        XCTAssertNil(folder("/Users/x/Pictures/a.png", modified), "只是改了内容不算新图")
        XCTAssertNil(folder("/Users/x/Pictures/Shots", FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsDir)), "文件夹不算")
        XCTAssertNil(folder("/Users/x/Desktop/note.txt", created), "不是图片不算")
        XCTAssertNil(folder("/Users/x/.Trash/a.png", created), "隐藏目录里的不算")
        XCTAssertNil(folder("/Users/x/Pictures/.a.png", created), "隐藏的临时文件不算")
        XCTAssertNil(folder("/Users/x/Library/Caches/com.google.Chrome/thumb.png", created), "缓存一直在写缩略图")
        XCTAssertNil(folder("/Users/x/Library/Application Support/Tally/shelf/thumbs/1.png", created), "Tally 自己写的不算")
    }
}
