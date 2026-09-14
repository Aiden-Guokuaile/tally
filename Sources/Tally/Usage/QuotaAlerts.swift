import Foundation

/// 一条配额提醒。
struct QuotaEvent: Equatable {
    enum Kind: Equatable {
        /// 涨过 80%，关联值是这次读到的整数百分比。
        case high(percent: Int)
        case exhausted
        case reset
    }

    let provider: ProviderID
    /// 窗口标签：「5 小时」「7 天」、Cursor 的「Cursor」、按模型分的周窗口「Fable」。
    let window: String
    let kind: Kind
    let resetsAt: Date?
}

/// 配额提醒的判定（docs/ai.md「配额提醒」）：按「提供方 + 窗口」记上一次读数，纯逻辑、不碰界面。
struct QuotaAlertTracker {
    static let highThreshold = 0.8
    /// 重置时刻往后挪超过这么久才算翻到下一个窗口：同一个窗口里接口报的重置时刻会有几秒到几分钟的抖动。
    static let resetShift: TimeInterval = 30 * 60
    /// 用量一下掉这么多也算重置：窗口没翻篇的话用量不会往回走。
    static let resetDrop = 0.2

    private var last: [String: UsageLimit] = [:]

    /// 喂一条新鲜读数，返回该提醒的事件；每个窗口第一次喂只记不报（开 app 时已经 90% 不该弹）。
    mutating func feed(provider: ProviderID, window: String, limit: UsageLimit) -> QuotaEvent? {
        let key = "\(provider.rawValue)|\(window)"
        defer { last[key] = limit }
        guard let previous = last[key] else { return nil }
        let event = { (kind: QuotaEvent.Kind) in QuotaEvent(provider: provider, window: window, kind: kind, resetsAt: limit.resetsAt) }

        var shifted = false
        if let before = previous.resetsAt, let after = limit.resetsAt {
            shifted = after.timeIntervalSince(before) > Self.resetShift
        }
        if shifted || previous.fraction - limit.fraction >= Self.resetDrop {
            return previous.fraction >= Self.highThreshold ? event(.reset) : nil
        }
        // 一步从 79% 跳到 100% 只报用完
        if previous.fraction < 1, limit.fraction >= 1 { return event(.exhausted) }
        if previous.fraction < Self.highThreshold, limit.fraction >= Self.highThreshold {
            return event(.high(percent: Int((limit.fraction * 100).rounded())))
        }
        return nil
    }
}
