import AppKit
import XCTest
@testable import Tally

final class NotchPanelTests: XCTestCase {

    /// 钉的是「为什么需要让路」这个前提：`runModal` 把模态窗口的 level 钉死在 `.modalPanel`，
    /// 面板比它高，所以 `NSAlert` / `NSOpenPanel` 天生就在面板底下（看不见也点不到）。
    /// 哪天面板 level 降到模态窗口之下，这条会红，提醒让路那套可以撤了。
    @MainActor
    func testPanelSitsAboveModalWindows() {
        _ = NSApplication.shared
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 620, height: 160))
        defer { panel.close() }
        XCTAssertGreaterThan(panel.level.rawValue, NSWindow.Level.modalPanel.rawValue,
                             "面板比模态窗口高，所以弹系统模态 UI 前必须 steppingAside 让路")
    }

    /// 让路期间要低于模态窗口，出来必须原样还原（`defer`，body 中途 return 也还原）。
    @MainActor
    func testSteppingAsideLowersThenRestores() {
        _ = NSApplication.shared
        let panel = NotchPanel(contentRect: CGRect(x: 0, y: 0, width: 620, height: 160))
        defer { panel.close() }
        let original = panel.level
        var levelDuringBody: NSWindow.Level?
        let returned = NotchPanel.steppingAside { () -> Int in
            levelDuringBody = panel.level
            return 7
        }
        XCTAssertEqual(returned, 7, "body 的返回值原样交出来")
        XCTAssertLessThan(try XCTUnwrap(levelDuringBody).rawValue, NSWindow.Level.modalPanel.rawValue,
                          "让路期间要低于模态窗口，否则弹框还是被盖住")
        XCTAssertEqual(panel.level, original, "出来还原成原来的 level")
    }
}

final class PanelKeyTests: XCTestCase {

    private let one = UInt16(18), five = UInt16(23), six = UInt16(22), nine = UInt16(25), zero = UInt16(29), comma = UInt16(43)

    func testDigitsSwitchPagesOnlyWhenEnabledAndUnmodified() {
        XCTAssertEqual(PanelKey.action(keyCode: one, modifiers: [], pageKeys: true, sessionKeys: false), .page(0))
        XCTAssertEqual(PanelKey.action(keyCode: nine, modifiers: [], pageKeys: true, sessionKeys: false), .page(8))
        XCTAssertEqual(PanelKey.action(keyCode: five, modifiers: [.capsLock, .numericPad], pageKeys: true, sessionKeys: false), .page(4),
                       "大写锁、小键盘标记不算按了修饰键")
        XCTAssertNil(PanelKey.action(keyCode: one, modifiers: [], pageKeys: false, sessionKeys: true), "开关关着就放过")
        XCTAssertNil(PanelKey.action(keyCode: one, modifiers: [.option], pageKeys: true, sessionKeys: true), "⌥1 不归面板")
    }

    func testCommandDigitsJumpToTenSessionsOnlyWhenEnabled() {
        XCTAssertEqual(PanelKey.action(keyCode: one, modifiers: [.command], pageKeys: true, sessionKeys: true), .session(0))
        XCTAssertEqual(PanelKey.action(keyCode: six, modifiers: [.command], pageKeys: true, sessionKeys: true), .session(5), "第 6 个会话也有键")
        XCTAssertEqual(PanelKey.action(keyCode: nine, modifiers: [.command], pageKeys: true, sessionKeys: true), .session(8))
        XCTAssertEqual(PanelKey.action(keyCode: zero, modifiers: [.command], pageKeys: true, sessionKeys: true), .session(9), "⌘0 是第 10 个")
        XCTAssertNil(PanelKey.action(keyCode: zero, modifiers: [], pageKeys: true, sessionKeys: true), "单按 0 不归面板")
        XCTAssertNil(PanelKey.action(keyCode: zero, modifiers: [.command], pageKeys: true, sessionKeys: false))
        XCTAssertNil(PanelKey.action(keyCode: one, modifiers: [.command], pageKeys: true, sessionKeys: false), "开关关着就放过")
        XCTAssertNil(PanelKey.action(keyCode: one, modifiers: [.command, .shift], pageKeys: true, sessionKeys: true))
        XCTAssertEqual(PanelKey.sessionShortcutLabel(0), "⌘1")
        XCTAssertEqual(PanelKey.sessionShortcutLabel(8), "⌘9")
        XCTAssertEqual(PanelKey.sessionShortcutLabel(9), "⌘0")
        XCTAssertNil(PanelKey.sessionShortcutLabel(10), "第 11 个起没有键")
    }

    func testCommandCommaAlwaysOpensSettings() {
        XCTAssertEqual(PanelKey.action(keyCode: comma, modifiers: [.command], pageKeys: false, sessionKeys: false), .settings)
        XCTAssertNil(PanelKey.action(keyCode: comma, modifiers: [], pageKeys: true, sessionKeys: true), "单按逗号不管")
        XCTAssertNil(PanelKey.action(keyCode: 0, modifiers: [], pageKeys: true, sessionKeys: true), "别的键放过")
    }
}
