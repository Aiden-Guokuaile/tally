import XCTest
@testable import Tally

final class NotchGeometryTests: XCTestCase {

    /// 本机 14 寸 M3 Max 的实测参数。
    private let builtIn14 = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        auxiliaryTopLeftWidth: 663,
        auxiliaryTopRightWidth: 664,
        safeAreaTop: 32
    )

    func testClosedSizeOn14Inch() {
        XCTAssertEqual(NotchGeometry.closedSize(builtIn14), CGSize(width: 189, height: 32))
    }

    func testOpenHeightFollowsContentWithinBounds() {
        XCTAssertEqual(NotchGeometry.openHeight(content: 10, screenHeight: 982), 160, "小内容也不低于下限")
        XCTAssertEqual(NotchGeometry.openHeight(content: 200, screenHeight: 982), 256, "正常就是内容加固定部分")
        XCTAssertEqual(NotchGeometry.openHeight(content: 2000, screenHeight: 982), 589, "上限是屏幕高的六成")
    }

    func testPeekFollowsContentWidthWithinBounds() {
        let closed = CGSize(width: 189, height: 32)
        XCTAssertEqual(NotchGeometry.peekSize(closed: closed, content: 100), CGSize(width: 189, height: 32 + NotchGeometry.peekDrop), "内容窄就和刘海一样宽")
        XCTAssertEqual(NotchGeometry.peekSize(closed: closed, content: 240).width, 240 + 2 * NotchGeometry.peekPadding, "内容宽就跟着内容")
        XCTAssertEqual(NotchGeometry.peekSize(closed: closed, content: 900).width, NotchGeometry.peekMaxWidth, "有上限")
        XCTAssertLessThan(NotchGeometry.peekSize(closed: closed, content: 240).height, NotchGeometry.minOpenHeight, "提示态比最矮的展开态还矮")
    }

    func testHeaderGapCoversNotchWithMargin() {
        XCTAssertEqual(NotchGeometry.headerGap(closedWidth: 189), 197)
    }

    func testPinnedClickClosesOnlyOnTheNotch() {
        let panel = CGSize(width: NotchGeometry.openWidth, height: 300)
        let notch = CGSize(width: 189, height: 32)
        XCTAssertTrue(NotchGeometry.hitsNotch(CGPoint(x: 310, y: 290), panelSize: panel, notch: notch), "刘海正中")
        XCTAssertTrue(NotchGeometry.hitsNotch(CGPoint(x: 310 + 98, y: 270), panelSize: panel, notch: notch), "刘海那段的边上也算")
        XCTAssertFalse(NotchGeometry.hitsNotch(CGPoint(x: 100, y: 290), panelSize: panel, notch: notch), "左边的页签")
        XCTAssertFalse(NotchGeometry.hitsNotch(CGPoint(x: 520, y: 290), panelSize: panel, notch: notch), "右边的按钮")
        XCTAssertFalse(NotchGeometry.hitsNotch(CGPoint(x: 310, y: 200), panelSize: panel, notch: notch), "刘海下面的页内容")
    }

    func testNoNotchReturnsNil() {
        var external = builtIn14
        external.safeAreaTop = 0
        XCTAssertNil(NotchGeometry.closedSize(external))
    }

    func testFrameIsTopCentered() {
        let frame = NotchGeometry.frame(for: CGSize(width: 189, height: 32), on: builtIn14)
        XCTAssertEqual(frame.midX, 756, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 982, accuracy: 0.001)
        XCTAssertEqual(frame.size, CGSize(width: 189, height: 32))
    }

    func testOpenFrameStaysAnchoredWhenScreenIsOffset() {
        // 外接屏排在左边时内建屏的 frame 原点不在 0，锚点仍要跟着内建屏走。
        var offset = builtIn14
        offset.frame = CGRect(x: 2560, y: -100, width: 1512, height: 982)
        let frame = NotchGeometry.frame(for: CGSize(width: NotchGeometry.openWidth, height: 320), on: offset)
        XCTAssertEqual(frame.midX, 2560 + 756, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, 882, accuracy: 0.001)
    }
}
