import XCTest
@testable import Tally

final class ShelfStoreTests: XCTestCase {

    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("tally-shelf-\(UUID().uuidString)")
    }

    private func sampleFile(_ dir: URL, _ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("hello".utf8).write(to: url)
        return url
    }

    @MainActor
    func testAddCopiesAndPersistsAndRemoveDeletes() async throws {
        let root = temp()
        let source = try sampleFile(root.appendingPathComponent("src"), "a.txt")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        store.setEnabled(true)
        await store.add(urls: [source, source])
        XCTAssertEqual(store.items.count, 2, "同名文件各自一个目录，不冲突")
        XCTAssertEqual(store.items.first?.name, "a.txt")
        XCTAssertEqual(store.items.first?.size, 5)
        for item in store.items {
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(item).path))
        }
        // 重开一个实例读同一目录：索引还在
        let again = ShelfStore(directory: root.appendingPathComponent("shelf"))
        again.setEnabled(true)
        XCTAssertEqual(again.items, store.items)
        let first = store.items[0]
        store.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(first).path))
        XCTAssertEqual(store.items.count, 1)
        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testDisabledHoldsNothingAndIgnoresAdds() async throws {
        let root = temp()
        let source = try sampleFile(root.appendingPathComponent("src"), "b.txt")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        await store.add(urls: [source])
        XCTAssertTrue(store.items.isEmpty, "没开就不收")
        store.setEnabled(true)
        await store.add(urls: [source])
        store.start()
        XCTAssertEqual(store.thumbnails.count, 1, "这页可见时缩略图在内存里")
        store.stop()
        XCTAssertTrue(store.thumbnails.isEmpty, "不可见就放掉")
        store.setEnabled(false)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("shelf/index.json").path), "关掉不删磁盘上的东西")
        try? FileManager.default.removeItem(at: root)
    }

    func testExpiry() {
        let now = Date()
        let fresh = ShelfItem(id: "f", name: "f", size: 1, addedAt: now.addingTimeInterval(-ShelfStore.retention + 60).timeIntervalSince1970 * 1000, source: nil)
        let old = ShelfItem(id: "o", name: "o", size: 1, addedAt: now.addingTimeInterval(-ShelfStore.retention - 60).timeIntervalSince1970 * 1000, source: nil)
        XCTAssertEqual(ShelfStore.expired([fresh, old], now: now), [old])
    }

    /// 老索引里没有 source 这个键，解出来得是 nil，不能整条读不出来。
    func testLegacyIndexWithoutSourceDecodes() throws {
        let json = Data(#"[{"id":"a","name":"a.txt","size":5,"addedAt":1}]"#.utf8)
        let items = try JSONDecoder().decode([ShelfItem].self, from: json)
        XCTAssertEqual(items.count, 1)
        XCTAssertNil(items[0].source)
    }

    /// 剪切交出去的是**来源文件本身**，不是架上那份快照：这样访达做的是一次改名，盘上不多一份副本，
    /// 也就没有「多出来的那份该不该进废纸篓」这回事。来源没了才退回架上那份。
    @MainActor
    func testCutHandsOverSourceItself() async throws {
        let root = temp()
        let source = try sampleFile(root.appendingPathComponent("src"), "cut.txt")
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        store.setEnabled(true)
        await store.add(urls: [source])
        let item = try XCTUnwrap(store.items.first)
        XCTAssertEqual(item.source, source.path, "拖进来时记下原路径")
        XCTAssertEqual(store.cutURL(item), source, "来源还在就交来源")
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(store.cutURL(item), store.fileURL(item), "来源没了退回架上那份")
        try? FileManager.default.removeItem(at: root)
    }

    /// 右键「移动到…」：搬的是来源本身，架上那份跟着清掉，废纸篓里不该多出东西；
    /// 目标已有同名文件就报错，且什么都不动。
    @MainActor
    func testMoveToMovesSourceOrRefusesOnConflict() async throws {
        let root = temp()
        let name = "tally-test-\(UUID().uuidString).txt"
        let source = try sampleFile(root.appendingPathComponent("src"), name)
        let store = ShelfStore(directory: root.appendingPathComponent("shelf"))
        store.setEnabled(true)
        await store.add(urls: [source])
        let item = try XCTUnwrap(store.items.first)

        // 目标目录先放一个同名的：不能默默覆盖
        let destination = root.appendingPathComponent("dst")
        _ = try sampleFile(destination, name)
        XCTAssertNotNil(store.moveTo(item, directory: destination), "同名冲突要报错")
        XCTAssertEqual(store.items.count, 1, "报错了就什么都不动")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "来源也还在")

        try FileManager.default.removeItem(at: destination.appendingPathComponent(name))
        XCTAssertNil(store.moveTo(item, directory: destination))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path), "来源搬到了目标目录")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "原处没有了")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(item).path), "架上那份删掉")
        let trashed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(name)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.path), "不该往废纸篓里丢东西")
        try? FileManager.default.removeItem(at: root)
    }
}
