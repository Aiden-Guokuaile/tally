import Foundation
import IOKit.ps

/// 值得在闭合态弹一下的电池事件。
enum BatteryEvent: Equatable {
    case pluggedIn(percent: Int)
    case unplugged(percent: Int)
    /// 放电中跌到阈值以下，每次放电每个阈值只报一次。
    case low(percent: Int, threshold: Int)
    case full
}

/// 事件判定，纯函数：拿上一次和这一次的电池读数比。
enum BatteryRule {

    static let lowThresholds = [20, 10]

    /// `warned` 记这次放电里已经报过的阈值；接上电源就清空。
    /// 接拔电看 `externalConnected` 不看 `state`：接着电源但没在充（优化充电停在 80%）时 state 不是充电，拔掉前后都不是充电，按 state 判就没有跃迁。
    static func event(previous: BatteryHealth?, current: BatteryHealth, warned: inout Set<Int>) -> BatteryEvent? {
        guard let previous else { return nil }
        if !previous.externalConnected, current.externalConnected {
            warned = []
            return .pluggedIn(percent: current.percent)
        }
        if previous.externalConnected, !current.externalConnected {
            return .unplugged(percent: current.percent)
        }
        if !current.externalConnected {
            let crossed = lowThresholds.filter { current.percent <= $0 && !warned.contains($0) }
            guard let lowest = crossed.min() else { return nil }
            warned.formUnion(crossed)
            return .low(percent: current.percent, threshold: lowest)
        }
        if previous.state != .full, current.state == .full {
            return .full
        }
        return nil
    }
}

/// 订阅电源变化通知（`IOPSNotificationCreateRunLoopSource`，事件驱动不轮询），每次变化重读一次 IOKit 注册表。
/// 关掉就摘掉 run loop source，什么都不留。
@MainActor
final class BatteryWatcher {

    static let shared = BatteryWatcher()

    var onEvent: ((BatteryEvent) -> Void)?

    private var source: CFRunLoopSource?
    private var last: BatteryHealth?
    private var warned: Set<Int> = []

    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard source == nil else { return }
            last = BatteryHealth.read()
            let context = Unmanaged.passUnretained(self).toOpaque()
            guard let created = IOPSNotificationCreateRunLoopSource({ context in
                guard let context else { return }
                let watcher = Unmanaged<BatteryWatcher>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in watcher.changed() }
            }, context)?.takeRetainedValue() else {
                Log.error("电源通知订阅失败")
                return
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
            source = created
        } else if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = nil
            last = nil
            warned = []
        }
    }

    private func changed() {
        guard let current = BatteryHealth.read() else { return }
        let event = BatteryRule.event(previous: last, current: current, warned: &warned)
        last = current
        if let event { onEvent?(event) }
    }
}
