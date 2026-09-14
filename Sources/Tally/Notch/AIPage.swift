import SwiftUI

/// 「AI」页：上半是会话卡片，下半是各家用量的单行条卡片。
struct AIPage: View {
    var store = SessionStore.shared
    var usage = UsageStore.shared
    /// 会话卡片翻到「已关闭」那一页没有。不落盘：每次展开面板都回到会话——已关闭的点下去会开新终端，平时不该摆在手边。
    @State private var showingClosed = false

    var body: some View {
        VStack(spacing: 8) {
            let closedCount = store.sessions.filter { $0.state == .ended }.count
            Card(showingClosed ? "已关闭" : "会话", symbol: showingClosed ? "clock.arrow.circlepath" : "terminal", tint: .green,
                 accessory: closedCount > 0 || showingClosed
                    ? AnyView(ClosedPageToggle(count: closedCount, showingClosed: $showingClosed)) : nil) {
                SessionsPage(showingClosed: showingClosed)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            Card("用量", symbol: "chart.bar.fill", tint: .blue) {
                UsageStrip(usage: usage)
            }
        }
    }
}

/// 会话卡片标题行右边：「已关闭 N ›」翻到已关闭那一页，「‹ 会话」翻回来。
struct ClosedPageToggle: View {
    let count: Int
    @Binding var showingClosed: Bool

    var body: some View {
        Button { showingClosed.toggle() } label: {
            Text(showingClosed ? "‹ 会话" : "已关闭 \(count) ›")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .background(Capsule().fill(.white.opacity(0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 每个已开启的提供方一行：名字与费用、两条配额（带重置时刻）。
struct UsageStrip: View {
    var usage: UsageStore

    private var rows: [(ProviderID, UsageResult)] {
        ProviderID.allCases.compactMap { id in usage.results[id].map { (id, $0) } }
    }

    var body: some View {
        let now = Date()
        VStack(spacing: 3) {
            if rows.isEmpty {
                Text("没有开启的提供方")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(rows, id: \.0) { id, result in
                UsageStripRow(provider: id, result: result, now: now)
            }
        }
    }
}

struct UsageStripRow: View {
    let provider: ProviderID
    let result: UsageResult
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            main
            // 按模型分的周窗口（Fable 那条）另起一行，和上面的名字列对齐：一行放不下三条
            if case .success(let snapshot) = result, case let scopedLimits = snapshot.scopedLimits.filter({ !$0.limit.isExpired(at: now) }),
               !scopedLimits.isEmpty {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 150, height: 1)
                    ForEach(scopedLimits, id: \.label) { scoped in
                        QuotaBar(label: scoped.label, limit: scoped.limit, stale: snapshot.limitsStale, now: now, window: provider.limitWindows.week)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var main: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    ProviderLogo(name: provider.logoName)
                    Text(provider.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                    if case .success(let snapshot) = result, let plan = snapshot.plan {
                        Text(plan)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.white.opacity(0.8)))
                    }
                }
                // 只有 Claude、Codex 有本地日志算出来的花费；别家画「$0.00」会让人以为真没花钱
                if case .success(let snapshot) = result, provider.reportsSpend {
                    UsageFigures(today: snapshot.today, week: snapshot.week)
                }
            }
            .frame(width: 150, alignment: .leading)

            switch result {
            case .loading:
                Text("加载中").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                Spacer()
            case .failure(let message):
                Text(message).font(.system(size: 10)).foregroundStyle(.red).lineLimit(1)
                Spacer()
            case .success(let snapshot):
                // 过了重置时间的窗口不画：下一轮刷新之前那几分钟，手里的百分比说的还是上一个窗口
                if let limit = snapshot.sessionLimit, !limit.isExpired(at: now) {
                    QuotaBar(label: provider.stripLabels.session, limit: limit, stale: snapshot.limitsStale, now: now, window: provider.limitWindows.session)
                }
                if let limit = snapshot.weekLimit, !limit.isExpired(at: now) {
                    QuotaBar(label: provider.stripLabels.week, limit: limit, stale: snapshot.limitsStale, now: now, window: provider.limitWindows.week)
                }
                ForEach(Array(snapshot.balances.enumerated()), id: \.offset) { _, balance in
                    BalanceLabel(balance: balance)
                }
                if let note = snapshot.limitsNote {
                    Text(note).font(.system(size: 9)).foregroundStyle(.red).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}
