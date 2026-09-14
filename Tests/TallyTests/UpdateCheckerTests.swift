import XCTest
@testable import Tally

/// 新版本提示（docs/hooks.md「发版与更新」）。
final class UpdateCheckerTests: XCTestCase {

    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.0.1", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.10", than: "1.9"), "按整数比，不按字符串")
        XCTAssertTrue(UpdateChecker.isNewer("v2.0.0-beta", than: "1.0"), "后缀去掉再比")
        XCTAssertFalse(UpdateChecker.isNewer("v1.0.0", than: "1.0"), "补零后一样不算新")
        XCTAssertFalse(UpdateChecker.isNewer("0.9.9", than: "1.0.0"))
        XCTAssertFalse(UpdateChecker.isNewer("nightly", than: "1.0.0"), "认不出的版本号不提示")
        XCTAssertFalse(UpdateChecker.isNewer("1..2", than: "1.0.0"))
    }

    func testParsesLatestRelease() throws {
        let json = #"{"tag_name":"v1.2.0","html_url":"https://github.com/Aiden-Guokuaile/tally/releases/tag/v1.2.0","assets":[]}"#
        let release = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.page.absoluteString, "https://github.com/Aiden-Guokuaile/tally/releases/tag/v1.2.0")
        XCTAssertNil(UpdateChecker.parse(Data(#"{"message":"Not Found"}"#.utf8)))
        XCTAssertNil(UpdateChecker.parse(Data(#"{"tag_name":"latest","html_url":"https://x"}"#.utf8)))
    }

    func testHomebrewDetection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-caskroom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(UpdateChecker.installedByHomebrew(caskrooms: ["/nonexistent", dir.path]))
        XCTAssertFalse(UpdateChecker.installedByHomebrew(caskrooms: ["/nonexistent"]))
    }

    func testUpdatePeek() {
        let peek = Peek.update("1.2.0")
        XCTAssertEqual(peek.style, .update)
        XCTAssertEqual(peek.title, "Tally 1.2.0")
        XCTAssertNil(peek.sessionId, "不可点")
        XCTAssertEqual(peek.id, Peek.update("1.2.0").id, "同一个版本同一个 id")
    }
}
