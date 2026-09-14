import SwiftUI

/// 配额用色和 statusline 一致：85% 以上红，60% 以上黄，其余绿。
func quotaColor(_ fraction: Double) -> Color {
    let percent = fraction * 100
    if percent >= 85 { return .red }
    if percent >= 60 { return .yellow }
    return .green
}

/// 一条配额：标签、条、整数百分比（缓存陈旧时加「~」）、重置时刻。紧凑到一行能放两条。
struct QuotaBar: View {
    let label: String
    let limit: UsageLimit
    let stale: Bool
    let now: Date

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 36, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(quotaColor(limit.fraction))
                        .frame(width: max(4, geometry.size.width * min(1, limit.fraction)))
                }
            }
            .frame(width: 50, height: 6)
            Text("\(Int((limit.fraction * 100).rounded()))%\(stale ? "~" : "")")
                .font(.metric(11, .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 32, alignment: .trailing)
            Text(ResetLabel.text(for: limit.resetsAt, now: now, style: .short) ?? "")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 58, alignment: .leading)
                .lineLimit(1)
        }
    }
}

/// 重置时间的文案。24 小时内给「HH:mm」，更远给「M/d HH:mm」，已过给「已重置」，没有就 nil。
/// `.long` 在时刻后面带「 重置」两个字；`.short` 给 ↻ 前缀，用在一行放两条的紧凑布局里。
enum ResetLabel {
    enum Style { case long, short }

    static func text(for date: Date?, now: Date, calendar: Calendar = .current, style: Style = .long) -> String? {
        guard let date else { return nil }
        if date <= now { return "已重置" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = date.timeIntervalSince(now) < 24 * 3600 ? "HH:mm" : "M/d HH:mm"
        let clock = formatter.string(from: date)
        return style == .long ? clock + " 重置" : "↻" + clock
    }
}

/// token 数按 1000 进制缩写：1234 → 1.2k，2400000 → 2.4M。小数是 0 就不带小数点。
/// 不用 `ByteFormat`：那个是 1024 进制的字节数，token 不是字节。
enum TokenFormat {
    static func short(_ tokens: Int) -> String {
        let n = max(0, tokens)
        if n < 1_000 { return "\(n)" }
        // 按舍入之后的值挑单位：999,950 舍到一位小数是 1000.0，按原值挑的话会写成「1000k」
        for (scale, suffix) in [(1_000.0, "k"), (1_000_000.0, "M")] where oneDecimal(Double(n) / scale) < 1_000 {
            return trim(Double(n) / scale) + suffix
        }
        return trim(Double(n) / 1_000_000_000) + "B"
    }

    private static func oneDecimal(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    private static func trim(_ value: Double) -> String {
        let rounded = oneDecimal(value)
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }
}

/// 两行：「今日 $x · 24.1M」「本周 $y · 312M」。token 是输入加输出（输入含缓存读写）。
/// 排成两行而不是挤一行：左格只有 150pt，一行放不下两个窗口的费用加 token。
struct UsageFigures: View {
    let today: UsageTotals
    let week: UsageTotals

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            line("今日", today)
            line("本周", week)
        }
        .font(.system(size: 9))
        .foregroundStyle(.white.opacity(0.8))
        .lineLimit(1)
    }

    private func line(_ label: String, _ totals: UsageTotals) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.white.opacity(0.45))
            Text(String(format: "$%.2f", totals.costUSD)).font(.metric(10, .medium))
            if totals.hasUnpricedModel {
                Text("+未定价").foregroundStyle(.orange)
            }
            Text("·").foregroundStyle(.white.opacity(0.3))
            Text(TokenFormat.short(totals.inputTokens + totals.outputTokens))
                .font(.metric(10, .regular))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}
