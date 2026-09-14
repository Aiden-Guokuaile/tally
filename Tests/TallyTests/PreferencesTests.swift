import XCTest
@testable import Tally

final class PreferencesTests: XCTestCase {

    func testOldFileWithoutProviderKeysDecodesToDefaults() throws {
        let old = Data(#"{"launchAtLogin":true}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: old)
        XCTAssertTrue(prefs.launchAtLogin)
        XCTAssertTrue(prefs.enableClaude)
        XCTAssertTrue(prefs.enableCodex)
        XCTAssertTrue(prefs.enableAntigravity)
        XCTAssertTrue(prefs.enableCursor)
    }

    @MainActor
    func testStoreRoundTrips() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-prefs-\(UUID().uuidString)")
            .appendingPathComponent("preferences.json")
        let store = PreferencesStore(url: url)
        store.prefs.enableCursor = false
        store.prefs.launchAtLogin = true
        let reloaded = PreferencesStore(url: url)
        XCTAssertFalse(reloaded.prefs.enableCursor)
        XCTAssertTrue(reloaded.prefs.launchAtLogin)
        XCTAssertTrue(reloaded.prefs.enableClaude)
    }

    func testOldFileWithoutPageKeysDecodesToDefaults() throws {
        let old = Data(#"{"launchAtLogin":true}"#.utf8)
        let prefs = try JSONDecoder().decode(Preferences.self, from: old)
        XCTAssertEqual(prefs.lastPage, "ai")
        XCTAssertTrue(prefs.hotKeyEnabled)
    }

    func testOldFileWithoutFeatureKeysDecodesToDefaults() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"launchAtLogin":true}"#.utf8))
        XCTAssertTrue(prefs.hoverToOpen)
        XCTAssertTrue(prefs.keepAwakeButton)
        XCTAssertTrue(prefs.keepAwakeDisplay, "默认连屏幕一起保持，和 caffeinate -dims 的习惯一致")
        XCTAssertTrue(prefs.batteryPeek)
        XCTAssertTrue(prefs.privacyDots)
        XCTAssertFalse(prefs.hideFromCapture, "截屏隐藏默认关：截图验证流程要能拍到面板")
        XCTAssertNil(prefs.keepAwakeCustomMinutes, "自定义时长没设过就是没有这一档")
        XCTAssertEqual(prefs.peekSessionSeconds, 5)
        XCTAssertEqual(prefs.peekBatterySeconds, 3)
        XCTAssertEqual(prefs.peekTapAction, "terminal", "默认跳回对应终端")
        XCTAssertTrue(prefs.pageNumberKeys, "数字键切页签默认开")
        XCTAssertTrue(prefs.sessionCommandKeys, "⌘1–⌘5 跳会话默认开：只在面板展开时归面板")
        XCTAssertTrue(prefs.keepClosedSessions, "已关闭的会话默认留着接着聊")
        XCTAssertTrue(prefs.quotaPeek, "配额提醒默认开")
        XCTAssertTrue(prefs.sessionSound, "提示音默认开")
        XCTAssertFalse(prefs.hideInFullScreen, "全屏隐藏默认关：升级后行为不变")
        XCTAssertTrue(prefs.notifyWithoutNotch, "没有刘海屏时改发通知默认开：合盖接外接屏的人不然只剩一声响")
        XCTAssertFalse(prefs.screenshotsToShelf, "截图进文件架默认关：要用户点选文件夹才有授权")
        XCTAssertNil(prefs.screenshotFolder)
        // 手改成离谱的秒数要夹回来，不然提示条要么永不收要么一闪而过
        let wild = try JSONDecoder().decode(Preferences.self, from: Data(#"{"peekSessionSeconds":999,"peekBatterySeconds":0,"peekTapAction":"乱写的"}"#.utf8))
        XCTAssertEqual(wild.peekSessionSeconds, 30)
        XCTAssertEqual(wild.peekBatterySeconds, 2)
        XCTAssertEqual(wild.peekTapAction, "terminal", "认不出的回落到默认")
        let off = try JSONDecoder().decode(Preferences.self, from: Data(#"{"privacyDots":false,"hideFromCapture":true}"#.utf8))
        XCTAssertFalse(off.privacyDots)
        XCTAssertTrue(off.hideFromCapture)
    }

    func testLastPageOnlyAcceptsPanelPages() throws {
        let system = try JSONDecoder().decode(Preferences.self, from: Data(#"{"lastPage":"system"}"#.utf8))
        XCTAssertEqual(system.lastPage, "system")
        let settings = try JSONDecoder().decode(Preferences.self, from: Data(#"{"lastPage":"settings"}"#.utf8))
        XCTAssertEqual(settings.lastPage, "ai")
        let bogus = try JSONDecoder().decode(Preferences.self, from: Data(#"{"lastPage":"bogus","hotKeyEnabled":false}"#.utf8))
        XCTAssertEqual(bogus.lastPage, "ai")
        XCTAssertFalse(bogus.hotKeyEnabled)
        let removed = try JSONDecoder().decode(Preferences.self, from: Data(#"{"lastPage":"tasks"}"#.utf8))
        XCTAssertEqual(removed.lastPage, "ai", "任务页删掉后存过它的文件回落 ai")
        XCTAssertEqual(LaunchOptions.Page.panelPages, [.ai, .network, .system, .apps, .shelf])
        XCTAssertEqual(LaunchOptions.Page.visible(shelf: false), [.ai, .network, .system, .apps])
        XCTAssertEqual(LaunchOptions.Page.visible(shelf: true), LaunchOptions.Page.panelPages)
    }

    func testEnabledKeyPathsWrite() {
        var prefs = Preferences()
        prefs[keyPath: ProviderID.antigravity.enabledKey] = false
        XCTAssertFalse(prefs.enableAntigravity)
        XCTAssertTrue(prefs[keyPath: ProviderID.claude.enabledKey])
    }
}
