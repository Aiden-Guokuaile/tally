import XCTest
@testable import Tally

final class HoverGraceTests: XCTestCase {

    private let tall = CGRect(x: 100, y: 500, width: 620, height: 400)   // AppKit 坐标，原点在左下
    private let short = CGRect(x: 100, y: 700, width: 620, height: 200)

    func testInsideCurrentFrameEndsGrace() {
        let v = HoverGrace.judge(mouse: CGPoint(x: 300, y: 800), frame: short, shrunkFrom: tall)
        XCTAssertTrue(v.inside)
        XCTAssertFalse(v.keepGrace, "回到面板里宽限就结束")
    }

    func testStillInOldAreaCountsAsInside() {
        let v = HoverGrace.judge(mouse: CGPoint(x: 300, y: 600), frame: short, shrunkFrom: tall)
        XCTAssertTrue(v.inside, "面板从脚下缩走，光标还在老区域里，不算离开")
        XCTAssertTrue(v.keepGrace)
    }

    func testOutsideBothIsLeaving() {
        let v = HoverGrace.judge(mouse: CGPoint(x: 300, y: 100), frame: short, shrunkFrom: tall)
        XCTAssertFalse(v.inside)
        XCTAssertFalse(v.keepGrace)
        XCTAssertFalse(HoverGrace.judge(mouse: CGPoint(x: 300, y: 600), frame: short, shrunkFrom: nil).inside, "没有宽限就按当前 frame 判")
    }

    /// 面板顶边就是屏幕顶边：光标甩到刘海上卡在最顶那一行（mouseLocation.y == frame.maxY）。
    /// 追踪区算它进来了，这里也得算在里面，不然首次悬停开了又收（每次装完第一次必闪）。
    func testScreenTopRowCountsAsInside() {
        let open = CGRect(x: 446, y: 556, width: 620, height: 426)   // 14 寸屏上展开态的 frame，maxY = 982
        XCTAssertTrue(HoverGrace.judge(mouse: CGPoint(x: 756, y: 982), frame: open, shrunkFrom: nil).inside)
        XCTAssertTrue(HoverGrace.judge(mouse: CGPoint(x: 756, y: 982), frame: CGRect(x: 446, y: 700, width: 620, height: 282), shrunkFrom: open).inside,
                      "缩小宽限的老区域顶边同理")
        XCTAssertFalse(HoverGrace.judge(mouse: CGPoint(x: 756, y: 555.9), frame: open, shrunkFrom: nil).inside, "底边以下才是离开")
    }
}
