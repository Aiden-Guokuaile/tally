import XCTest
@testable import Tally

final class ClaudeLimitsCacheTests: XCTestCase {

    private func makeCache(_ content: String?) throws -> ClaudeLimitsCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-limits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let content {
            try content.write(to: dir.appendingPathComponent("rate-limits.json"), atomically: true, encoding: .utf8)
        }
        return ClaudeLimitsCache(directory: dir)
    }

    private let sample = #"{"five_hour":{"used_percentage":88,"resets_at":1788855600},"seven_day":{"used_percentage":26,"resets_at":1789077600}}"#

    func testMissingFileOrNonObjectIsNil() throws {
        XCTAssertNil(try makeCache(nil).read())
        XCTAssertNil(try makeCache("[1,2]").read())
        XCTAssertNil(try makeCache("not json").read())
    }

    func testOnlyOneWindowPresent() throws {
        let weekOnly = try makeCache(#"{"seven_day":{"used_percentage":26,"resets_at":1789077600}}"#).read()
        XCTAssertNil(weekOnly?.session)
        XCTAssertEqual(weekOnly?.week?.used, 0.26)

        let sessionOnly = try makeCache(#"{"five_hour":{"used_percentage":50}}"#).read()
        XCTAssertNil(sessionOnly?.week)
        XCTAssertEqual(sessionOnly?.session?.used, 0.5)
        XCTAssertNil(sessionOnly?.session?.resetsAt)
    }

    func testBothWindowsMissingIsNil() throws {
        XCTAssertNil(try makeCache("{}").read())
        XCTAssertNil(try makeCache(#"{"five_hour":{"used_percentage":"x"}}"#).read())
    }

    func testSampleParsesToFractionsAndSeconds() throws {
        let limits = try XCTUnwrap(try makeCache(sample).read())
        XCTAssertEqual(limits.session?.used, 0.88)
        XCTAssertEqual(limits.session?.limit, 1)
        XCTAssertEqual(limits.session?.resetsAt, Date(timeIntervalSince1970: 1_788_855_600))
        XCTAssertEqual(limits.week?.used, 0.26)
        XCTAssertFalse(limits.isStale)
    }

    func testOverLimitIsNotClamped() throws {
        let limits = try XCTUnwrap(try makeCache(#"{"five_hour":{"used_percentage":130}}"#).read())
        XCTAssertEqual(limits.session?.used, 1.3)
        XCTAssertEqual(limits.session?.fraction, 1)
    }

    func testStaleAfterTenMinutes() throws {
        let cache = try makeCache(sample)
        let mtime = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: cache.fileURL.path))[.modificationDate] as? Date
        )
        XCTAssertEqual(cache.read(now: mtime.addingTimeInterval(600))?.isStale, false)
        XCTAssertEqual(cache.read(now: mtime.addingTimeInterval(601))?.isStale, true)
        // mtime 在未来（now 早于 mtime）不算陈旧
        XCTAssertEqual(cache.read(now: mtime.addingTimeInterval(-5))?.isStale, false)
    }

    func testIgnoresSpendLimitKey() throws {
        let limits = try makeCache(#"{"five_hour":{"used_percentage":10},"spend_limit":{"used_percentage":99}}"#).read()
        XCTAssertEqual(limits?.session?.used, 0.1)
        XCTAssertNil(limits?.week)
    }
}
