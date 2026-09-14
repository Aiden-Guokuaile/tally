import XCTest
import Network
@testable import Tally

/// 记住每个路径的回调，测试自己扮演 socket。
private final class FakeMihomo: MihomoRequesting {
    var lines: [String: (Data) -> Void] = [:]
    var closes: [String: (Error?) -> Void] = [:]
    var paths: [String] = []
    /// 按发出顺序记住每个请求的回调，测重叠的两轮要用。
    var requests: [(path: String, close: (Error?) -> Void)] = []

    func get(_ path: String, onLine: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void) -> NWConnection? {
        paths.append(path)
        lines[path] = onLine
        closes[path] = onClose
        requests.append((path, onClose))
        return nil
    }
}

final class NetworkStoreTests: XCTestCase {

    private static let proxies = """
    {"proxies":{
      "GLOBAL":{"type":"Selector","now":"海外出口","all":["海外出口","国内出口","Claude","自动","国内绕过","国内台湾","备用一","备用二","DIRECT"]},
      "海外出口":{"type":"Selector","now":"节点甲","all":[]},
      "国内出口":{"type":"Selector","now":"节点丙","all":[]},
      "Claude":{"type":"Selector","now":"节点乙","all":[]},
      "自动":{"type":"URLTest","now":"x","all":[]},
      "国内绕过":{"type":"Selector","now":"节点丙","all":[]},
      "国内台湾":{"type":"Selector","now":"节点甲","all":[]},
      "备用一":{"type":"Selector","now":"a","all":[]},
      "备用二":{"type":"Selector","now":"b","all":[]},
      "孤儿组":{"type":"Selector","now":"c","all":[]},
      "DIRECT":{"type":"Direct"}
    }}
    """

    func testParseProxiesFollowsGlobalOrderAndCaps() throws {
        let groups = try XCTUnwrap(NetworkStore.parseProxies(Data(Self.proxies.utf8)))
        XCTAssertEqual(groups.map(\.name), ["海外出口", "国内出口", "Claude", "国内绕过", "国内台湾", "备用一"],
                       "GLOBAL 与 URLTest 排除、按 GLOBAL.all 次序、不在其中的孤儿组丢掉、第 7 个起截断")
        XCTAssertEqual(groups[2].now, "节点乙")
    }

    func testParseConfigs() {
        let configs = NetworkStore.parseConfigs(Data(#"{"mode":"rule","tun":{"enable":true}}"#.utf8))
        XCTAssertEqual(configs?.mode, "rule")
        XCTAssertEqual(configs?.tun, true)
        XCTAssertNil(NetworkStore.parseConfigs(Data("not json".utf8)))
    }

    @MainActor
    func testHistoryIsCappedAndStopClears() {
        let store = NetworkStore(client: FakeMihomo(), coreSocketExists: { false })
        XCTAssertNil(store.up, "还没量到就是 nil，页面显示「—」")
        for i in 0..<70 { store.record((up: i, down: i * 2)) }
        XCTAssertEqual(store.history.count, NetworkStore.historyLength)
        XCTAssertEqual(store.history.first?.up, 10, "最老的被挤掉")
        XCTAssertEqual(store.down, 138)
        store.stop()
        XCTAssertTrue(store.history.isEmpty)
        XCTAssertNil(store.up)
    }

    @MainActor
    func testNoRequestsWithoutCoreSocket() {
        let fake = FakeMihomo()
        var checks = 0
        let store = NetworkStore(client: fake, coreSocketExists: { checks += 1; return false })
        XCTAssertEqual(checks, 0, "socket 在不在是刷新快照时才查")
        store.start()
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(fake.paths, [], "没有内核 socket 一个请求都不发")
        XCTAssertEqual(store.proxy?.coreAvailable, false, "代理卡片人人都有，内核那段没有 socket 就不画")
        XCTAssertNil(store.proxy?.core)
        XCTAssertNotNil(store.primary, "主接口不依赖 Watchdog")
        XCTAssertFalse(store.primary?.dns.isEmpty ?? true)
        store.stop()
    }

    @MainActor
    func testProxyStateNeedsBothRequests() {
        let fake = FakeMihomo()
        let store = NetworkStore(client: fake, coreSocketExists: { true })
        store.start()
        XCTAssertEqual(Set(fake.paths), ["/configs", "/proxies"])
        XCTAssertEqual(store.proxy?.coreAvailable, true)
        XCTAssertNil(store.proxy?.core, "两个都没回来之前不判")

        fake.closes["/configs"]?(MihomoError.notRunning)
        XCTAssertNil(store.proxy?.core)
        fake.lines["/proxies"]?(Data(Self.proxies.utf8))
        fake.closes["/proxies"]?(nil)
        XCTAssertEqual(store.proxy?.core, .notRunning, "/configs 失败就是没响应")

        store.stop()
        store.start()
        fake.lines["/configs"]?(Data(#"{"mode":"global","tun":{"enable":false}}"#.utf8))
        fake.closes["/configs"]?(nil)
        XCTAssertEqual(store.proxy?.core, .notRunning, "上一轮的状态留着，直到这一轮两个都回来")
        fake.closes["/proxies"]?(MihomoError.badStatus("500"))
        XCTAssertEqual(store.proxy?.core, .notRunning, "/proxies 失败也是没响应")

        fake.paths.removeAll()
        // 下一轮两个都成功
        store.stop()
        store.start()
        fake.lines["/configs"]?(Data(#"{"mode":"rule","tun":{"enable":true}}"#.utf8))
        fake.closes["/configs"]?(nil)
        fake.lines["/proxies"]?(Data(Self.proxies.utf8))
        fake.closes["/proxies"]?(nil)
        guard case .running(let mode, let tun, let groups)? = store.proxy?.core else { return XCTFail("应为 running") }
        XCTAssertEqual(mode, "rule")
        XCTAssertEqual(tun, true)
        XCTAssertEqual(groups.count, 6)
        store.stop()
    }

    @MainActor
    func testLateRepliesFromSupersededRoundAreIgnored() {
        let fake = FakeMihomo()
        let store = NetworkStore(client: fake, coreSocketExists: { true })
        store.start()
        store.refreshSnapshot()
        XCTAssertEqual(fake.requests.count, 4, "两轮各两个请求")
        // 第一轮这才回来：慢响应不能盖住新一轮
        fake.requests[0].close(nil)
        fake.requests[1].close(nil)
        XCTAssertNil(store.proxy?.core, "作废那轮的回复不算数")
        fake.lines["/configs"]?(Data(#"{"mode":"rule","tun":{"enable":true}}"#.utf8))
        fake.lines["/proxies"]?(Data(Self.proxies.utf8))
        fake.requests[2].close(nil)
        fake.requests[3].close(nil)
        guard case .running(let mode, _, _)? = store.proxy?.core else { return XCTFail("新一轮该生效") }
        XCTAssertEqual(mode, "rule")
        store.stop()
    }
}
