import XCTest
@testable import Tally

final class PageSummaryTests: XCTestCase {

    func testSummaries() {
        XCTAssertEqual(PageSummary.ai(sessions: 0, waiting: 0), "没有在跑的会话")
        XCTAssertEqual(PageSummary.ai(sessions: 3, waiting: 0), "3 个会话")
        XCTAssertEqual(PageSummary.ai(sessions: 3, waiting: 1), "3 个会话 · 1 个在等你")
        XCTAssertEqual(PageSummary.network(interface: "Wi-Fi en0", down: "117 KB/s", up: "49 KB/s"), "Wi-Fi en0 · ↓117 KB/s ↑49 KB/s")
        XCTAssertEqual(PageSummary.network(interface: nil, down: nil, up: nil), "—")
        XCTAssertEqual(PageSummary.system(chip: "Apple M3 Max", memory: "18.4 / 48 GB"), "Apple M3 Max · 内存 18.4 / 48 GB")
        XCTAssertEqual(PageSummary.apps(total: 12, hidden: 5), "12 个在跑 · 5 个 Dock 里看不见")
        XCTAssertEqual(PageSummary.apps(total: 0, hidden: 0), "没有在跑的 app")
        XCTAssertEqual(PageSummary.shelf(count: 0, fileMinutes: 1440, screenshotMinutes: 30), "拖文件到刘海上暂存")
        XCTAssertEqual(PageSummary.shelf(count: 2, fileMinutes: 1440, screenshotMinutes: 30), "2 项 · 文件留 1 天 · 截图留 30 分钟")
    }
}
