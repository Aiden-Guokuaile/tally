import XCTest
@testable import Tally

final class ResetLabelTests: XCTestCase {

    private var shanghai: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    // 2026-09-08 16:00 +08:00
    private let now = Date(timeIntervalSince1970: 1_788_854_400)

    func testNilWhenNoResetTime() {
        XCTAssertNil(ResetLabel.text(for: nil, now: now, calendar: shanghai))
    }

    func testAlreadyReset() {
        XCTAssertEqual(ResetLabel.text(for: now, now: now, calendar: shanghai), "已重置")
        XCTAssertEqual(ResetLabel.text(for: now.addingTimeInterval(-1), now: now, calendar: shanghai), "已重置")
    }

    func testWithin24HoursShowsClockOnly() {
        // 1788855600 = 16:20 +08:00
        XCTAssertEqual(ResetLabel.text(for: Date(timeIntervalSince1970: 1_788_855_600), now: now, calendar: shanghai), "16:20 重置")
    }

    func testBeyond24HoursShowsDate() {
        // 1789077600 = 9/11 06:00 +08:00
        XCTAssertEqual(ResetLabel.text(for: Date(timeIntervalSince1970: 1_789_077_600), now: now, calendar: shanghai), "9/11 06:00 重置")
    }

    func testShortStyleUsesArrowPrefix() {
        XCTAssertEqual(ResetLabel.text(for: Date(timeIntervalSince1970: 1_788_855_600), now: now, calendar: shanghai, style: .short), "↻16:20")
        XCTAssertEqual(ResetLabel.text(for: Date(timeIntervalSince1970: 1_789_077_600), now: now, calendar: shanghai, style: .short), "↻9/11 06:00")
        XCTAssertEqual(ResetLabel.text(for: now, now: now, calendar: shanghai, style: .short), "已重置")
    }
}
