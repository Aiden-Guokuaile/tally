import XCTest
@testable import Tally

/// 新截图自动放进文件架（docs/shelf.md「截图自动放进来」）。
final class ScreenshotWatcherTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 照系统截图的样子写一个文件：带 `kMDItemIsScreenCapture` = true（二进制 plist）。
    private func writeScreenshot(_ url: URL) throws {
        try Data("png".utf8).write(to: url)
        let value = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let status = value.withUnsafeBytes { setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", $0.baseAddress, value.count, 0, 0) }
        XCTAssertEqual(status, 0)
    }

    func testRecognizesTheScreenCaptureMarkNotTheName() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shot = dir.appendingPathComponent("a.png")
        try writeScreenshot(shot)
        let lookalike = dir.appendingPathComponent("截屏2026-09-14 10.00.00.png")
        try Data("png".utf8).write(to: lookalike)
        XCTAssertTrue(ScreenshotWatcher.isScreenCapture(shot))
        XCTAssertFalse(ScreenshotWatcher.isScreenCapture(lookalike), "名字像截图不算，认的是系统写的标记")
    }

    func testListingSkipsHiddenFilesAndReportsUnreadable() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.png"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        XCTAssertEqual(ScreenshotWatcher.listing(dir)?.map(\.url.lastPathComponent), ["a.png"])
        XCTAssertNil(ScreenshotWatcher.listing(dir.appendingPathComponent("missing")))
    }

    @MainActor
    func testUnreadableFolderSaysWhy() {
        let watcher = ScreenshotWatcher()
        watcher.start(folder: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertNotNil(watcher.problem, "读不了要亮在设置里，不默默失效")
        XCTAssertNil(watcher.folder)
    }

    @MainActor
    func testReportsNewScreenshotsOnce() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeScreenshot(dir.appendingPathComponent("old.png"))
        let watcher = ScreenshotWatcher()
        defer { watcher.stop() }
        var reported: [[String]] = []
        watcher.onScreenshots = { reported.append($0.map(\.lastPathComponent)) }
        watcher.start(folder: dir)
        XCTAssertNil(watcher.problem)

        try writeScreenshot(dir.appendingPathComponent("new.png"))
        try Data("note".utf8).write(to: dir.appendingPathComponent("note.txt"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(reported, [["new.png"]], "开始盯之前就在的不算，不带标记的不算")

        try FileManager.default.moveItem(at: dir.appendingPathComponent("new.png"), to: dir.appendingPathComponent("renamed.png"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(reported, [["new.png"]], "改个名还是同一个文件，不重复放")
    }

    /// 盯着的目录被删掉：描述符再也不来事件，得停下并把原因亮出来，不能一直假装在盯。
    @MainActor
    func testFolderRemovedAfterStartSaysWhy() async throws {
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let watcher = ScreenshotWatcher()
        defer { watcher.stop() }
        watcher.start(folder: dir)
        XCTAssertNil(watcher.problem)
        try FileManager.default.removeItem(at: dir)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertNotNil(watcher.problem)
        XCTAssertNil(watcher.folder, "停下了，改设置时 start 会重来")
    }
}
