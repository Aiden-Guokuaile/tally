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

    /// 截图工具自己的文件夹（Lens 这类不写标记）：新图片都算；系统截图位置才认标记。
    func testMarkIsOnlyRequiredInTheSystemLocation() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unmarked = dir.appendingPathComponent("Lens-20260914-153724-715.png")
        try Data("png".utf8).write(to: unmarked)
        let note = dir.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: note)
        XCTAssertTrue(ScreenshotWatcher.accepts(unmarked, requireMark: false), "工具的文件夹里新图片都算")
        XCTAssertFalse(ScreenshotWatcher.accepts(note, requireMark: false), "不是图片不算")
        XCTAssertFalse(ScreenshotWatcher.accepts(unmarked, requireMark: true), "桌面上的普通图片不能被当成截图收走")

        XCTAssertTrue(ScreenshotWatcher.isSystemLocation(URL(fileURLWithPath: "/x/Desktop/"), system: URL(fileURLWithPath: "/x/Desktop")))
        XCTAssertFalse(ScreenshotWatcher.isSystemLocation(URL(fileURLWithPath: "/x/T/Lens"), system: URL(fileURLWithPath: "/x/Desktop")))
    }

    /// 系统截图快捷键全关（本机实测 28/29/30/31/184 都是 enabled = 0）才提示；没写进偏好的键是默认开着的。
    func testSystemShortcutsDisabledNeedsAllFiveOff() {
        func entry(_ on: Int) -> [String: Any] { ["enabled": NSNumber(value: on), "value": ["type": "standard"]] }
        let allOff: [String: Any] = ["28": entry(0), "29": entry(0), "30": entry(0), "31": entry(0), "184": entry(0), "64": entry(1)]
        XCTAssertTrue(ScreenshotWatcher.systemShortcutsDisabled(allOff))
        var oneOn = allOff
        oneOn["30"] = entry(1)
        XCTAssertFalse(ScreenshotWatcher.systemShortcutsDisabled(oneOn), "⌘⇧4 还开着就有新截图")
        var missing = allOff
        missing["184"] = nil
        XCTAssertFalse(ScreenshotWatcher.systemShortcutsDisabled(missing), "没写进偏好的是默认开着")
        XCTAssertFalse(ScreenshotWatcher.systemShortcutsDisabled(nil))
    }

    /// 藏在 /var/folders 下的文件夹选择面板点不进去，可以直接粘贴路径。
    func testTypedPath() throws {
        let base = try tempDir()
        defer { try? FileManager.default.removeItem(at: base) }
        let lens = base.appendingPathComponent("Lens", isDirectory: true)
        try FileManager.default.createDirectory(at: lens, withIntermediateDirectories: true)

        XCTAssertEqual(ScreenshotWatcher.folder(fromTyped: "  \"\(lens.path)\" \n")?.path, lens.path, "粘贴时带的空白和引号去掉")
        XCTAssertNil(ScreenshotWatcher.folder(fromTyped: lens.appendingPathComponent("missing").path))
        let file = base.appendingPathComponent("a.png")
        try Data().write(to: file)
        XCTAssertNil(ScreenshotWatcher.folder(fromTyped: file.path), "文件不是文件夹")
        XCTAssertNil(ScreenshotWatcher.folder(fromTyped: "   "))
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
        XCTAssertEqual(reported, [["new.png"]], "开始盯之前就在的不算，不是图片的不算")

        try FileManager.default.moveItem(at: dir.appendingPathComponent("new.png"), to: dir.appendingPathComponent("renamed.png"))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(reported, [["new.png"]], "改个名还是同一个文件，不重复放")
    }

    /// 截图工具放在临时目录里的文件夹会被系统清掉、下次存图又建回来：回来了要自动接着盯，不能一直停着。
    @MainActor
    func testComesBackWhenTheFolderReappears() async throws {
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("Lens")
        let watcher = ScreenshotWatcher()
        watcher.retryInterval = 0.2
        defer { watcher.stop() }
        watcher.start(folder: dir)
        XCTAssertNotNil(watcher.problem, "文件夹还没有")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertNil(watcher.problem, "回来了就自动接着盯")
        XCTAssertEqual(watcher.folder, dir)
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
