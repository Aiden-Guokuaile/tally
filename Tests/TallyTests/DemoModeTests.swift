import XCTest
@testable import Tally

final class DemoModeTests: XCTestCase {

    func testLaunchOptionsRecognisesDemoAlongsideOpen() {
        XCTAssertTrue(LaunchOptions.parse(["Tally", "--demo"]).demo)
        let both = LaunchOptions.parse(["Tally", "--demo", "--open", "network"])
        XCTAssertTrue(both.demo)
        XCTAssertEqual(both.openPage, .network, "--demo 不吞掉后面的 --open")
        let openOnly = LaunchOptions.parse(["Tally", "--open", "ai"])
        XCTAssertFalse(openOnly.demo)
        XCTAssertEqual(openOnly.openPage, .ai)
    }

    /// 测试进程不许进演示模式：进了的话各 store 的 shared 全是假数据，别的用例测的就不是真路径。
    func testDemoModeIsOffUnderTests() {
        XCTAssertFalse(DemoMode.isOn)
    }

    func testSessionFixturesCoverEveryGroupAndNoneLooksStale() {
        let now = Date()
        let sessions = DemoData.sessions(now: now)
        XCTAssertEqual(Set(sessions.map { $0.group(now: now) }), Set(SessionRecord.Group.allCases))
        XCTAssertTrue(sessions.filter { $0.state != .ended }.allSatisfy { !$0.isStale(now: now) }, "没关闭的会话不该画成失联")
        XCTAssertTrue(sessions.compactMap(\.pid).allSatisfy { $0 > 99_999 }, "pid 不能落在 macOS 真进程的范围里")
        XCTAssertEqual(Set(sessions.map(\.sessionId)).count, sessions.count)
        let peek = sessions.first { $0.sessionId == DemoData.peekSessionId }
        XCTAssertEqual(peek?.state, .done)
        XCTAssertEqual(peek?.title, "修复支付回调重复入账")
    }

    func testFixturesMentionNoHomeFolderButDemo() {
        let now = Date()
        var text = ""
        dump(DemoData.sessions(now: now), to: &text)
        dump(DemoData.shelfItems(now: now), to: &text)
        dump(DemoData.apps, to: &text)
        dump(DemoData.interface, to: &text)
        dump(DemoData.proxy, to: &text)
        dump(DemoData.hardware(now: now), to: &text)
        dump(DemoData.systemSample, to: &text)
        XCTAssertTrue(text.contains("/Users/demo/"), "确认 dump 真的带出了路径")
        let others = text.components(separatedBy: "/Users/").dropFirst().filter { !$0.hasPrefix("demo/") }
        XCTAssertEqual(others, [], "除了 /Users/demo 不许出现别的家目录")
    }

    func testNetworkAddressesAreInDocumentationRange() throws {
        let interface = DemoData.interface
        for address in [interface.address, interface.router] {
            let value = try XCTUnwrap(address)
            XCTAssertTrue(value.hasPrefix("192.0.2."), "\(value) 不在 192.0.2.0/24")
        }
    }

    func testDemoUsageResetsInTheFuture() async throws {
        let now = Date()
        for provider in DemoData.usageProviders {
            let snapshot = try await provider.fetchSnapshot(now: now)
            let limits = [snapshot.sessionLimit, snapshot.weekLimit].compactMap { $0 } + snapshot.scopedLimits.map(\.limit)
            for limit in limits {
                let reset = try XCTUnwrap(limit.resetsAt, "\(provider.id) 的配额没有重置时刻")
                XCTAssertGreaterThan(reset, now, "\(provider.id) 的配额一刷出来就过期，条不会画")
            }
            XCTAssertTrue(!limits.isEmpty || !snapshot.balances.isEmpty, "\(provider.id) 什么都没画")
        }
    }
}
