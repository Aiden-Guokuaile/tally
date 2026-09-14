import XCTest
@testable import Tally

/// 全屏 app 时隐藏面板的判定（docs/panel.md「全屏 app 时隐藏面板」）。数字取自 14 寸内建屏的实测窗口列表。
final class FullScreenDetectorTests: XCTestCase {

    private typealias W = FullScreenDetector.Window
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let menuBar = W(pid: 90, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33))

    private func judge(_ windows: [W], display: CGRect? = nil) -> Bool {
        FullScreenDetector.isFullScreen(windows: windows, display: display ?? self.display, safeTop: 32, selfPid: 1)
    }

    func testNativeFullScreenHasCoveringWindowAndNotchBand() {
        let app = W(pid: 500, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 949))
        let band = W(pid: 500, layer: 26, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33))
        XCTAssertTrue(judge([menuBar, app, band]))
    }

    func testMaximizedWindowIsNotFullScreen() {
        let maximized = W(pid: 500, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 949))
        XCTAssertFalse(judge([menuBar, maximized]), "最大化窗口位置和全屏一样，没有刘海那条带子上的窗口就不算")
        XCTAssertFalse(judge([menuBar, maximized, W(pid: 600, layer: 26, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33))]),
                       "带子上的窗口得是同一个 app 的")
    }

    func testOwnWindowsAndOtherDisplaysDoNotCount() {
        let own = [W(pid: 1, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 949)),
                   W(pid: 1, layer: 26, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33))]
        XCTAssertFalse(judge(own), "自己的窗口不算")

        let external = [W(pid: 500, layer: 0, bounds: CGRect(x: 1512, y: 25, width: 2560, height: 1415)),
                        W(pid: 500, layer: 26, bounds: CGRect(x: 1512, y: 0, width: 2560, height: 25))]
        XCTAssertFalse(judge(external), "外接屏上全屏不藏内建屏的面板")
        XCTAssertTrue(FullScreenDetector.isFullScreen(windows: external, display: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
                                                      safeTop: 24, selfPid: 1), "按传进来的那块屏判")
    }

    func testPartialWindowsDoNotCount() {
        let half = W(pid: 500, layer: 0, bounds: CGRect(x: 0, y: 33, width: 756, height: 949))
        let band = W(pid: 500, layer: 26, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33))
        XCTAssertFalse(judge([half, band]), "分屏的半边不算铺满")
        XCTAssertFalse(judge([]))
    }
}
