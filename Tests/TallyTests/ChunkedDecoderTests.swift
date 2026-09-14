import XCTest
@testable import Tally

final class ChunkedDecoderTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testSingleChunk() {
        var d = ChunkedDecoder()
        let out = d.feed(data("5\r\nhello\r\n"))
        XCTAssertEqual(out, [data("hello")])
        XCTAssertFalse(d.isFinished)
    }

    func testChunkSplitAcrossTwoFeeds() {
        var d = ChunkedDecoder()
        XCTAssertEqual(d.feed(data("b\r\nhello ")), [])
        XCTAssertEqual(d.feed(data("world\r\n")), [data("hello world")])
    }

    func testSizeLineWithExtension() {
        var d = ChunkedDecoder()
        XCTAssertEqual(d.feed(data("3;name=value\r\nabc\r\n")), [data("abc")])
    }

    func testTerminatingChunkFinishes() {
        var d = ChunkedDecoder()
        let out = d.feed(data("2\r\nok\r\n0\r\n\r\n"))
        XCTAssertEqual(out, [data("ok")])
        XCTAssertTrue(d.isFinished)
        XCTAssertEqual(d.feed(data("2\r\nno\r\n")), [], "结束后不再解")
    }

    // 切行

    func testTwoLinesInOneChunk() {
        var s = LineSplitter()
        XCTAssertEqual(s.feed(data("{\"a\":1}\n{\"a\":2}\n")), [data("{\"a\":1}"), data("{\"a\":2}")])
    }

    func testLineAcrossTwoChunks() {
        var s = LineSplitter()
        XCTAssertEqual(s.feed(data("{\"up\":")), [])
        XCTAssertEqual(s.feed(data("1}\n")), [data("{\"up\":1}")])
    }

    func testCRLFStrippedAndEmptyLinesDropped() {
        var s = LineSplitter()
        XCTAssertEqual(s.feed(data("a\r\n\r\n\nb\n")), [data("a"), data("b")])
    }

    func testTailDeliveredOnFlush() {
        var s = LineSplitter()
        XCTAssertEqual(s.feed(data("{\"mode\":\"rule\"}")), [])
        XCTAssertEqual(s.flush(), data("{\"mode\":\"rule\"}"))
        XCTAssertNil(s.flush(), "flush 过一次就空了")
    }
}
