import Foundation
import SystemConfiguration

/// 名字以 en 开头的接口（Wi-Fi、以太网、雷雳）的字节计数之和。32 位，会绕。
struct InterfaceCounters: Equatable {
    var received: UInt32
    var sent: UInt32
}

/// 默认路由走的接口。
struct PrimaryInterface: Equatable {
    var name: String
    var address: String?
    var router: String?
}

/// 全走公开 API：`getifaddrs` 给计数与地址，SystemConfiguration 的动态存储给主接口与网关。
/// `utun*`（TUN）不计入：它的流量最终还是从 en0 出去，加上会翻倍。
enum InterfaceSampler {

    static func counters() -> InterfaceCounters? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var total = InterfaceCounters(received: 0, sent: 0)
        var found = false
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            let name = String(cString: entry.pointee.ifa_name)
            // 计数只挂在 AF_LINK 条目上，AF_INET / AF_INET6 条目的 ifa_data 是空的
            guard name.hasPrefix("en"), let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK), let data = entry.pointee.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            total.received &+= stats.ifi_ibytes
            total.sent &+= stats.ifi_obytes
            found = true
        }
        return found ? total : nil
    }

    /// 环绕减法：计数绕回去了差值仍然对。received 是下行，sent 是上行。
    static func rate(previous: InterfaceCounters, current: InterfaceCounters, elapsed: TimeInterval) -> (up: Int, down: Int) {
        guard elapsed > 0 else { return (0, 0) }
        let down = Double(current.received &- previous.received) / elapsed
        let up = Double(current.sent &- previous.sent) / elapsed
        return (Int(up.rounded()), Int(down.rounded()))
    }

    static func primary() -> PrimaryInterface? {
        guard let store = SCDynamicStoreCreate(nil, "Tally" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = global["PrimaryInterface"] as? String else { return nil }
        return PrimaryInterface(name: name, address: ipv4Address(of: name), router: global["Router"] as? String)
    }

    static func ipv4Address(of name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard String(cString: entry.pointee.ifa_name) == name, let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}

import CoreWLAN

/// Wi-Fi 的信号与速率。CoreWLAN 读这些不要定位权限；SSID 要，所以不读。
struct WiFiInfo: Equatable {
    var rssi: Int
    var noise: Int
    var transmitRate: Double
    /// 读不到为 nil，页面显示「—」。
    var channel: Int?
}

/// 系统代理设置：任何代理软件都往这里写。关着的是 nil，开着是「host:port」。
struct ProxySettings: Equatable {
    var http: String?
    var https: String?
    var socks: String?
    /// 有 up 且带 IPv4 的 utun*：TUN 或 VPN 都算。
    var tunActive: Bool
}

extension InterfaceSampler {

    static func dns() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "Tally" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] else { return [] }
        return global["ServerAddresses"] as? [String] ?? []
    }

    /// 不是 Wi-Fi 网卡、没开或没连上都返回 nil。
    static func wifi(interface name: String) -> WiFiInfo? {
        guard let iface = CWWiFiClient.shared().interface(withName: name), iface.powerOn(), iface.rssiValue() != 0 else { return nil }
        return WiFiInfo(rssi: iface.rssiValue(), noise: iface.noiseMeasurement(),
                        transmitRate: iface.transmitRate(), channel: iface.wlanChannel()?.channelNumber)
    }

    static func systemProxy() -> ProxySettings {
        let dict = (SCDynamicStoreCopyProxies(nil) as? [String: Any]) ?? [:]
        return parseProxies(dict, tunActive: tunActive())
    }

    /// `SCDynamicStoreCopyProxies` 的字典：HTTPEnable / HTTPProxy / HTTPPort，HTTPS、SOCKS 同样三个键。
    static func parseProxies(_ dict: [String: Any], tunActive: Bool) -> ProxySettings {
        func endpoint(_ prefix: String) -> String? {
            guard (dict["\(prefix)Enable"] as? Int ?? 0) != 0,
                  let host = dict["\(prefix)Proxy"] as? String, !host.isEmpty,
                  let port = dict["\(prefix)Port"] as? Int else { return nil }
            return "\(host):\(port)"
        }
        return ProxySettings(http: endpoint("HTTP"), https: endpoint("HTTPS"), socks: endpoint("SOCKS"), tunActive: tunActive)
    }

    /// 系统自带的 utun0…3 只有 IPv6 链路本地地址；带 IPv4 的才是代理的 TUN 或 VPN。
    static func tunActive() -> Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard String(cString: entry.pointee.ifa_name).hasPrefix("utun"), let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET), Int32(entry.pointee.ifa_flags) & IFF_UP != 0 else { continue }
            return true
        }
        return false
    }
}
