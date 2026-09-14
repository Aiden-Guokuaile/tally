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

    /// 点菜单栏小恐龙打开（14 寸屏实测：恐龙按钮 x 1219–1284，刘海正中 756，展开态面板右边到 1066）：
    /// 光标从没进过面板，不给宽限的话 0.25 s 就收了——原来因此只能钉住，钉住又移开也不收。
    private let dinoButton = CGRect(x: 1219, y: 958, width: 65, height: 24)

    func testDinosaurStripReachesFromNotchToButton() {
        XCTAssertEqual(HoverGrace.menuBarStrip(button: dinoButton, notchMidX: 756), CGRect(x: 756, y: 958, width: 528, height: 24),
                       "按钮加上它到刘海正中那段菜单栏")
    }

    func testCursorOnDinosaurStripCountsAsInside() {
        let open = CGRect(x: 446, y: 556, width: 620, height: 426)
        let strip = HoverGrace.menuBarStrip(button: dinoButton, notchMidX: 756)
        let onDino = HoverGrace.judge(mouse: CGPoint(x: 1250, y: 970), frame: open, shrunkFrom: nil, openedFrom: strip)
        XCTAssertTrue(onDino.inside, "光标停在恐龙上不算离开")
        XCTAssertTrue(onDino.keepOpenedFrom)
        XCTAssertTrue(HoverGrace.judge(mouse: CGPoint(x: 1120, y: 982), frame: open, shrunkFrom: nil, openedFrom: strip).inside,
                      "顺着菜单栏（含屏幕最顶那一行）往面板滑，中间那段也算")
        let intoPanel = HoverGrace.judge(mouse: CGPoint(x: 900, y: 900), frame: open, shrunkFrom: nil, openedFrom: strip)
        XCTAssertTrue(intoPanel.inside)
        XCTAssertFalse(intoPanel.keepOpenedFrom, "进了面板就回到普通悬停")
        let away = HoverGrace.judge(mouse: CGPoint(x: 1250, y: 700), frame: open, shrunkFrom: nil, openedFrom: strip)
        XCTAssertFalse(away.inside, "往下移开就是离开，照常收起")
        XCTAssertFalse(away.keepOpenedFrom)
    }

    /// 切到系统页面板变矮，缩小宽限被换成当时的 frame；恐龙那块宽限得单独留着，不然光标还在恐龙上面板就收了。
    func testDinosaurGraceSurvivesShrinkGrace() {
        let tall = CGRect(x: 446, y: 556, width: 620, height: 426)
        let short = CGRect(x: 446, y: 700, width: 620, height: 282)
        let strip = HoverGrace.menuBarStrip(button: dinoButton, notchMidX: 756)
        let v = HoverGrace.judge(mouse: CGPoint(x: 1250, y: 970), frame: short, shrunkFrom: tall, openedFrom: strip)
        XCTAssertTrue(v.inside)
        XCTAssertFalse(v.keepGrace, "光标不在老区域里，缩小宽限照常结束")
        XCTAssertTrue(v.keepOpenedFrom)
    }
}
