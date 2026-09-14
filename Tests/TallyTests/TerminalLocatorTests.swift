import XCTest
@testable import Tally

final class TerminalLocatorTests: XCTestCase {

    private func kind(_ term: String?, running: Set<String> = []) -> BackendKind {
        TerminalLocator.kind(for: term) { running.contains($0) }
    }

    func testGhosttyAndMissingTermGoToGhostty() {
        XCTAssertEqual(kind(nil), .ghostty)
        XCTAssertEqual(kind(""), .ghostty)
        XCTAssertEqual(kind("ghostty"), .ghostty)
    }

    func testTerminalAppAndITerm() {
        XCTAssertEqual(kind("Apple_Terminal"), .terminalApp)
        XCTAssertEqual(kind("iTerm.app"), .iterm)
    }

    func testVscodePrefersWhicheverIsRunning() {
        XCTAssertEqual(kind("vscode", running: [TerminalLocator.cursor]), .editor(bundleId: TerminalLocator.cursor, name: "Cursor"))
        XCTAssertEqual(kind("vscode", running: [TerminalLocator.vscode, TerminalLocator.cursor]), .editor(bundleId: TerminalLocator.vscode, name: "VS Code"))
        XCTAssertEqual(kind("vscode"), .editor(bundleId: TerminalLocator.vscode, name: "VS Code"), "都没跑也给 VS Code，执行层再抛没在跑")
    }

    func testOtherKnownTerminalsOnlyActivate() {
        XCTAssertEqual(kind("WezTerm"), .activate(bundleId: "com.github.wez.wezterm", name: "WezTerm"))
        XCTAssertEqual(kind("WarpTerminal"), .activate(bundleId: "dev.warp.Warp-Stable", name: "Warp"))
        XCTAssertEqual(kind("kitty"), .activate(bundleId: "net.kovidgoyal.kitty", name: "kitty"))
    }

    /// 未授权（-1743）必须和「找不到窗口」分开：拒过之后系统不再弹框，
    /// 混在一起用户永远不知道要去系统设置里开。
    func testUnauthorizedScriptErrorBecomesPermissionFailure() {
        let denied: NSDictionary = [NSAppleScript.errorNumber: NSNumber(value: -1743),
                                    NSAppleScript.errorMessage: "Not authorized to send Apple events to Terminal."]
        XCTAssertEqual(TerminalLocator.failure(fromScriptError: denied, target: "Terminal"), .needsAutomationPermission("Terminal"))

        let other: NSDictionary = [NSAppleScript.errorNumber: NSNumber(value: -1728),
                                   NSAppleScript.errorMessage: "找不到对象"]
        XCTAssertEqual(TerminalLocator.failure(fromScriptError: other, target: "Terminal"), .scriptFailed("找不到对象"))
    }

    func testUnknownTermIsUnknown() {
        XCTAssertEqual(kind("SomethingElse"), .unknown)
    }

    func testDevicePathNormalization() {
        XCTAssertEqual(TerminalLocator.devicePath("ttys003"), "/dev/ttys003")
        XCTAssertEqual(TerminalLocator.devicePath("/dev/ttys003"), "/dev/ttys003")
    }

    @MainActor
    func testUnknownTermThrowsNotFound() async {
        let session = SessionRecord(sessionId: "s", term: "SomethingElse", state: .running, cwd: "/tmp", title: nil, transcriptPath: "", message: nil, updatedAt: 0)
        do {
            try await TerminalLocator.focus(session: session)
            XCTFail("认不出的终端应该抛 notFound")
        } catch {
            XCTAssertEqual(error as? TerminalLocator.Failure, .notFound)
        }
    }
}
