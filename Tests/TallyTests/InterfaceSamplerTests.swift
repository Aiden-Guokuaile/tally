import CoreWLAN
import XCTest
@testable import Tally

final class InterfaceSamplerTests: XCTestCase {

    func testRateUsesWrappingSubtractionAndElapsed() {
        let previous = InterfaceCounters(received: 4_294_967_000, sent: 100)
        let current = InterfaceCounters(received: 100, sent: 1_100)
        let rate = InterfaceSampler.rate(previous: previous, current: current, elapsed: 1)
        XCTAssertEqual(rate.down, 396, "计数绕回去了差值仍然对")
        XCTAssertEqual(rate.up, 1_000)
        let halved = InterfaceSampler.rate(previous: previous, current: current, elapsed: 2)
        XCTAssertEqual(halved.up, 500)
        XCTAssertEqual(InterfaceSampler.rate(previous: previous, current: current, elapsed: 0).up, 0, "没走过时间不除零")
    }

    /// 真机用例：没网的机器跳过，不算失败。
    func testRealCountersAndPrimaryInterface() throws {
        guard let counters = InterfaceSampler.counters() else { throw XCTSkip("没有 en 开头的网卡") }
        XCTAssertTrue(counters.received > 0 || counters.sent > 0)
        guard let primary = InterfaceSampler.primary() else { throw XCTSkip("没有默认路由") }
        XCTAssertTrue(primary.name.hasPrefix("en"), primary.name)
        XCTAssertNotNil(primary.address)
        XCTAssertEqual(primary.address, InterfaceSampler.ipv4Address(of: primary.name))
    }

    func testParseProxiesEnabledDisabledAndMissing() {
        let on: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7899,
                                 "HTTPSEnable": 0, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7899,
                                 "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7891]
        let parsed = InterfaceSampler.parseProxies(on, tunActive: true)
        XCTAssertEqual(parsed.http, "127.0.0.1:7899")
        XCTAssertNil(parsed.https, "Enable 为 0 就是关")
        XCTAssertEqual(parsed.socks, "127.0.0.1:7891")
        XCTAssertTrue(parsed.tunActive)
        let off = InterfaceSampler.parseProxies([:], tunActive: false)
        XCTAssertEqual(off, ProxySettings(http: nil, https: nil, socks: nil, tunActive: false), "缺键全算关")
        XCTAssertNil(InterfaceSampler.parseProxies(["HTTPEnable": 1, "HTTPProxy": "", "HTTPPort": 1], tunActive: false).http, "空主机不算开")
    }

    func testRealDNSAndWiFi() throws {
        _ = InterfaceSampler.systemProxy()
        XCTAssertNil(InterfaceSampler.wifi(interface: "lo0"), "回环不是 Wi-Fi")
        guard InterfaceSampler.primary() != nil else { throw XCTSkip("没有默认路由") }
        XCTAssertFalse(InterfaceSampler.dns().isEmpty, "联网的机器总有 DNS")
        guard let name = CWWiFiClient.shared().interface()?.interfaceName,
              let wifi = InterfaceSampler.wifi(interface: name) else { throw XCTSkip("没连 Wi-Fi") }
        XCTAssertLessThan(wifi.rssi, 0, "rssi 是负的 dBm")
    }
}
