import XCTest
import AppKit
@testable import Tally

final class SwipeTests: XCTestCase {

    /// 整个手势里第一次（也应是唯一一次）触发的方向。
    private func gesture(_ steps: [(CGFloat, CGFloat)]) -> SwipeTracker.Direction? {
        var tracker = SwipeTracker()
        XCTAssertNil(tracker.feed(phase: .began, deltaX: 0, deltaY: 0))
        var result: SwipeTracker.Direction?
        for (dx, dy) in steps {
            if let direction = tracker.feed(phase: .changed, deltaX: dx, deltaY: dy) {
                XCTAssertNil(result, "一次手势只触发一次")
                result = direction
            }
        }
        if let direction = tracker.feed(phase: .ended, deltaX: 0, deltaY: 0) {
            XCTAssertNil(result, "一次手势只触发一次")
            result = direction
        }
        return result
    }

    func testLeftSwipeIsNextRightIsPrevious() {
        XCTAssertEqual(gesture([(-25, 2), (-25, 3)]), .next)
        XCTAssertEqual(gesture([(30, 0), (30, 0)]), .previous)
    }

    func testThresholdAndAxisDominance() {
        XCTAssertNil(gesture([(-39, 0)]), "不到 40pt")
        XCTAssertEqual(gesture([(-40, 0)]), .next)
        XCTAssertNil(gesture([(-50, -80)]), "纵向更大就是在滚列表")
    }

    func testOneTriggerPerGestureAndNoBeganMeansNothing() {
        var tracker = SwipeTracker()
        XCTAssertNil(tracker.feed(phase: .changed, deltaX: -100, deltaY: 0), "没 began 的 changed 不算")
        XCTAssertNil(tracker.feed(phase: .ended, deltaX: 0, deltaY: 0))
        _ = tracker.feed(phase: .began, deltaX: 0, deltaY: 0)
        XCTAssertEqual(tracker.feed(phase: .changed, deltaX: -100, deltaY: 0), .next, "跨过阈值立刻触发，不等手指离开")
        XCTAssertNil(tracker.feed(phase: .changed, deltaX: -100, deltaY: 0), "同一次手势只触发一次")
        XCTAssertNil(tracker.feed(phase: .ended, deltaX: 0, deltaY: 0))
        XCTAssertNil(tracker.feed(phase: [], deltaX: -100, deltaY: 0), "鼠标滚轮和 momentum 没有 phase")
        _ = tracker.feed(phase: .began, deltaX: 0, deltaY: 0)
        _ = tracker.feed(phase: .changed, deltaX: -100, deltaY: 0)
        XCTAssertNil(tracker.feed(phase: .cancelled, deltaX: 0, deltaY: 0), "被系统取消的手势不翻页")
        XCTAssertNil(tracker.feed(phase: .ended, deltaX: 0, deltaY: 0))
    }

    func testShelfTabIsLastWhenEnabled() {
        let pages = LaunchOptions.Page.visible(shelf: true)
        XCTAssertEqual(SwipeTracker.page(after: .apps, direction: .next, in: pages), .shelf)
        XCTAssertNil(SwipeTracker.page(after: .shelf, direction: .next, in: pages))
    }

    func testThreeFingerSwipeDirection() {
        XCTAssertEqual(SwipeTracker.direction(fromSwipeDeltaX: -1), .next)
        XCTAssertEqual(SwipeTracker.direction(fromSwipeDeltaX: 1), .previous)
        XCTAssertNil(SwipeTracker.direction(fromSwipeDeltaX: 0))
    }

    func testPagingStopsAtEnds() {
        let pages = LaunchOptions.Page.visible(shelf: false)
        XCTAssertEqual(SwipeTracker.page(after: .ai, direction: .next, in: pages), .network)
        XCTAssertEqual(SwipeTracker.page(after: .network, direction: .previous, in: pages), .ai)
        XCTAssertNil(SwipeTracker.page(after: .ai, direction: .previous, in: pages))
        XCTAssertEqual(SwipeTracker.page(after: .system, direction: .next, in: pages), .apps)
        XCTAssertNil(SwipeTracker.page(after: .apps, direction: .next, in: pages))
        XCTAssertNil(SwipeTracker.page(after: .settings, direction: .next, in: pages), "不是面板页")
    }
}
