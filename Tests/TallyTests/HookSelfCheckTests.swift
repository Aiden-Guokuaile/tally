import XCTest
@testable import Tally

/// 设置页 hook 自检（docs/hooks.md「自检」）。
final class HookSelfCheckTests: XCTestCase {

    func testHeartbeatText() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func beat(_ secondsAgo: Double, _ event: String = "Stop") -> HookHeartbeat {
            HookHeartbeat(event: event, at: (now.timeIntervalSince1970 - secondsAgo) * 1000)
        }
        XCTAssertTrue(HookInstallModel.describeHeartbeat(nil, now: now).hasPrefix("还没收到过事件"))
        XCTAssertEqual(HookInstallModel.describeHeartbeat(beat(10), now: now), "最近收到事件：刚刚（Stop）")
        XCTAssertEqual(HookInstallModel.describeHeartbeat(beat(180, "PostToolUse"), now: now), "最近收到事件：3 分钟前（PostToolUse）")
        XCTAssertEqual(HookInstallModel.describeHeartbeat(beat(2 * 3600), now: now), "最近收到事件：2 小时前（Stop）")
        XCTAssertEqual(HookInstallModel.describeHeartbeat(beat(3 * 86400), now: now), "最近收到事件：3 天前（Stop）")
    }

    func testSelfTestVerdicts() {
        XCTAssertEqual(HookSelfTest.describe(timedOut: false, status: 0, wrote: true, milliseconds: 42, stderr: ""), "正常：42 ms 跑完并写出状态文件")
        XCTAssertTrue(HookSelfTest.describe(timedOut: true, status: nil, wrote: false, milliseconds: 3000, stderr: "").hasPrefix("3 秒没退出"))
        XCTAssertTrue(HookSelfTest.describe(timedOut: false, status: nil, wrote: false, milliseconds: 5, stderr: "").hasPrefix("被信号杀掉了"))
        XCTAssertEqual(HookSelfTest.describe(timedOut: false, status: 1, wrote: false, milliseconds: 5, stderr: "boom\n"), "退出码 1：boom")
        XCTAssertTrue(HookSelfTest.describe(timedOut: false, status: 0, wrote: false, milliseconds: 5, stderr: "").hasPrefix("跑完了但没写出状态文件"))
    }

    /// 拿编出来的 tally-hook 真跑一次：stdin 走文件重定向才喂得进去。
    func testSelfTestRunsTheBuiltHook() throws {
        // swift build 编出来叫 TallyHook，打进 app 包时 build-app.sh 才改名成 tally-hook
        let hook = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("TallyHook")
        guard FileManager.default.isExecutableFile(atPath: hook.path) else { throw XCTSkip("这次没编出 TallyHook：先 swift build") }
        // 和写进配置的命令一个样子：带引号的路径，Codex 侧跟 --provider codex
        XCTAssertTrue(HookSelfTest.run(command: "\"\(hook.path)\"").hasPrefix("正常"))
        XCTAssertTrue(HookSelfTest.run(command: "\"\(hook.path)\" --provider codex").hasPrefix("正常"))
        XCTAssertTrue(HookSelfTest.run(command: "\"/nonexistent/tally-hook\"").hasPrefix("退出码"), "装错位置的 hook 报出来")
    }

    @MainActor
    func testSelfTestRefusesWhenNotInstalled() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-selfcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let installer = HookInstaller(claudeSettings: dir.appendingPathComponent("settings.json"),
                                      codexHooks: dir.appendingPathComponent("hooks.json"),
                                      codexConfig: dir.appendingPathComponent("config.toml"),
                                      hookBinary: "/x/tally-hook", codexHashes: { [] })
        let model = HookInstallModel(installer: installer)
        model.selfTest(.claude)
        XCTAssertEqual(model.selfTests[.claude]?.hasPrefix("还没装好"), true, "配置里没有这条命令，二进制跑通了也证明不了 agent 调得通")
        XCTAssertFalse(model.busy.contains(.claude))
    }
}
