import AppKit
import XCTest
@testable import Tally

final class RunningAppsTests: XCTestCase {

    private func hidden(_ policy: NSApplication.ActivationPolicy, _ path: String, _ id: String) -> Bool? {
        RunningApps.isHidden(policy: policy, bundlePath: path, bundleIdentifier: id, home: "/Users/me")
    }

    func testRules() {
        XCTAssertEqual(hidden(.regular, "/Applications/Ghostty.app", "com.mitchellh.ghostty"), false, "Dock 里看得见的算，不是隐藏")
        XCTAssertEqual(hidden(.regular, "/System/Library/CoreServices/Finder.app", "com.apple.finder"), false, "regular 不管谁出的都算")
        XCTAssertEqual(hidden(.accessory, "/Applications/Raycast.app", "com.raycast.macos"), true)
        XCTAssertEqual(hidden(.accessory, "/Users/me/Applications/Foo.app", "org.foo"), true, "用户目录下的也算")
        XCTAssertNil(hidden(.prohibited, "/Applications/WPS.app/Contents/PlugIns/Menu.app", "com.kingsoft.menu"), "纯后台不算")
        XCTAssertNil(hidden(.accessory, "/Applications/WeChat.app/Contents/Frameworks/Helper.app", "com.tencent.helper"), "嵌在别的 app 包里的 Helper 不算")
        XCTAssertNil(hidden(.accessory, "/System/Library/CoreServices/Spotlight.app", "com.apple.Spotlight"), "系统目录的 accessory 不算")
        XCTAssertNil(hidden(.accessory, "/Applications/Shortcuts.app", "com.apple.shortcuts"), "苹果自己的 accessory 不算")
        XCTAssertEqual(hidden(.accessory, "/Applications/Tally.app", "com.aiden.tally"), true, "自己也列，平时是隐藏的")
        XCTAssertEqual(hidden(.regular, "/Applications/Tally.app", "com.aiden.tally"), false, "开着设置窗口时自己是 regular")
        XCTAssertEqual(hidden(.accessory, "/Applications/Whatsapp.app", "net.whatsapp"), true, "名字里带 app 三个字母不算嵌套")
    }

    func testSmallIconIsTiny() throws {
        let finder = try XCTUnwrap(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let icon = RunningAppsStore.smallIcon(pid: finder.processIdentifier, bundleURL: try XCTUnwrap(finder.bundleURL))
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(icon.representations.count, 1)
        XCTAssertLessThanOrEqual(icon.representations[0].pixelsWide, 36, "原图 32 个尺寸最大 2048px，缓存的必须是 36px 小图")
    }

    func testRealListIsSortedByMemoryDescending() throws {
        let apps = RunningApps.list()
        let memory = apps.map { $0.memory ?? 0 }
        XCTAssertEqual(memory, memory.sorted(by: >), "内存大的在前")
        if let tally = NSRunningApplication.runningApplications(withBundleIdentifier: "com.aiden.tally").first {
            XCTAssertTrue(apps.contains { $0.id == tally.processIdentifier }, "Tally 在跑就该列出自己")
        }
        // Finder 永远在跑且是 regular：它得在列表里、不算隐藏、有内存数
        let finder = try XCTUnwrap(apps.first { $0.bundleIdentifier == "com.apple.finder" }, "Finder 在跑就该列出来")
        XCTAssertFalse(finder.isHidden)
        XCTAssertNotNil(finder.memory)
        // 随便挑一个在跑的菜单栏 app 验证：它得在列表里且标为隐藏；一个都没有就跳过
        let running = NSWorkspace.shared.runningApplications.first { app in
            app.activationPolicy == .accessory && (app.bundleURL?.path.hasPrefix("/Applications/") ?? false)
                && !(app.bundleIdentifier ?? "").hasPrefix("com.apple.")
                && (app.bundleURL?.path.components(separatedBy: ".app").count ?? 0) == 2
        }
        guard let running else { throw XCTSkip("没有在跑的菜单栏 app") }
        let listed = try XCTUnwrap(apps.first { $0.id == running.processIdentifier }, "\(running.localizedName ?? "?") 在跑就该列出来")
        XCTAssertTrue(listed.isHidden)
        XCTAssertNotNil(listed.memory)
    }
}
