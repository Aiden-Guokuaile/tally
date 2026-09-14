import AppKit
import SwiftUI

/// 网络页：第一行「吞吐」「连接」并排；第二行只在有代理软件、系统代理开着或有 TUN 网卡时出现。
struct NetworkPage: View {
    var store = NetworkStore.shared

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Card("吞吐", symbol: "arrow.up.arrow.down", tint: .orange) {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Speed(arrow: "arrow.up", text: store.up.map(ByteFormat.rate) ?? "—", tint: .blue)
                            Speed(arrow: "arrow.down", text: store.down.map(ByteFormat.rate) ?? "—", tint: .green)
                        }
                        .frame(width: 130, alignment: .leading)
                        HistoryGraph(history: store.history)
                            .frame(height: 40)
                    }
                }
                Card("连接", symbol: "wifi", tint: .cyan) {
                    ForEach(connectionLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                }
                .frame(width: 250)
            }
            if let proxy = store.proxy, showsProxyCard(proxy) {
                ProxyCard(proxy: proxy)
            }
            Spacer(minLength: 0)
        }
    }

    private var connectionLines: [String] {
        guard let primary = store.primary else { return ["—"] }
        let kind = primary.wifi.map { "Wi-Fi \(primary.name) · \($0.rssi) dBm" } ?? "有线 \(primary.name)"
        return [
            kind,
            "本机 \(primary.address ?? "—") · 网关 \(primary.router ?? "—")",
            "DNS \(primary.dns.isEmpty ? "—" : primary.dns.joined(separator: ", "))",
        ]
    }

    private func showsProxyCard(_ proxy: ProxyInfo) -> Bool {
        proxy.app != nil || proxy.settings.http != nil || proxy.settings.https != nil || proxy.settings.socks != nil || proxy.settings.tunActive
    }

    private struct Speed: View {
        let arrow: String
        let text: String
        let tint: Color

        var body: some View {
            HStack(spacing: 6) {
                Image(systemName: arrow)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
                    .frame(width: 14)
                Text(text)
                    .font(.metric(17, .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}

/// 代理卡片：标题行只放图标 + 软件名 + 右侧「打开 ▸」，端口 / TUN / 模式降到第二行做成小标签，
/// 有内核接口时各组两列排。卡片任何地方单击都能打开那个软件。
private struct ProxyCard: View {
    let proxy: ProxyInfo

    var body: some View {
        card
            .contentShape(Rectangle())
            .onTapGesture {
                if let app = proxy.app { ProxyAppDetector.open(app) }
            }
    }

    private var card: some View {
        Card {
            HStack(spacing: 8) {
                if let app = proxy.app, let icon = ProxyAppDetector.icon(of: app) {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                }
                Text(proxy.app?.name ?? "代理")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let app = proxy.app {
                    Button {
                        ProxyAppDetector.open(app)
                    } label: {
                        Text("打开 ▸")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if !tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.08)))
                    }
                }
            }
            if case .running(_, _, let groups)? = proxy.core, !groups.isEmpty {
                // 两列不是三列：三列每格只剩 200pt，节点名一长就贴边。组名给个最小宽度，
                // 同一列的节点名才对得齐；比最小宽度长的照常撑开，不截断。
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), spacing: 6) {
                    ForEach(groups, id: \.name) { group in
                        HStack(spacing: 10) {
                            Text(group.name)
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(minWidth: 56, alignment: .leading)
                            Text(group.now).foregroundStyle(.white.opacity(0.85))
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11))
                        .lineLimit(1)
                    }
                }
                .padding(.top, 1)
            } else if proxy.coreAvailable, proxy.core == .notRunning {
                Text("代理内核没有响应")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    /// 「HTTP 127.0.0.1:7899」「TUN 开」「模式 rule」，一项一个小标签。
    /// 原来这些和软件名用「·」串成一条长文本挤在标题行里，扫不出哪段是哪段。
    private var tags: [String] {
        var tags: [String] = []
        if let http = proxy.settings.http {
            tags.append("HTTP \(http)")
        } else if let https = proxy.settings.https {
            tags.append("HTTPS \(https)")
        } else if let socks = proxy.settings.socks {
            tags.append("SOCKS \(socks)")
        }
        if case .running(let mode, let tun, _)? = proxy.core {
            if let tun { tags.append("TUN \(tun ? "开" : "关")") }
            if let mode { tags.append("模式 \(mode)") }
        } else if proxy.settings.tunActive {
            tags.append("TUN 有")
        }
        return tags
    }
}

/// 最近 60 秒的折线（画法照 Atoll 的 MiniGraph）：下行绿、上行蓝，各自一条线加一片往下淡的渐变面，
/// 按窗口内的峰值缩放，不满 60 个点靠右。
struct HistoryGraph: View {
    let history: [(up: Int, down: Int)]

    var body: some View {
        GeometryReader { geometry in
            let peak = CGFloat(max(1, history.map { max($0.up, $0.down) }.max() ?? 1))
            let down = history.map { CGFloat($0.down) / peak }
            let up = history.map { CGFloat($0.up) / peak }
            ZStack {
                series(down, in: geometry.size, color: .green)
                series(up, in: geometry.size, color: .blue)
            }
        }
    }

    /// 一条序列：线 1.5pt，面从 0.3 淡到 0.05。
    private func series(_ values: [CGFloat], in size: CGSize, color: Color) -> some View {
        ZStack {
            Self.area(values, in: size)
                .fill(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.05)], startPoint: .top, endPoint: .bottom))
            Self.line(values, in: size)
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }

    /// 折线下面封到底边的那片面。
    private static func area(_ values: [CGFloat], in size: CGSize) -> Path {
        var path = line(values, in: size)
        guard let last = values.indices.last else { return path }
        path.addLine(to: CGPoint(x: x(last, count: values.count, width: size.width), y: size.height))
        path.addLine(to: CGPoint(x: x(0, count: values.count, width: size.width), y: size.height))
        path.closeSubpath()
        return path
    }

    /// 60 个槽位，最新的在最右。
    private static func x(_ index: Int, count: Int, width: CGFloat) -> CGFloat {
        let slot = width / CGFloat(max(1, NetworkStore.historyLength - 1))
        return width - CGFloat(count - 1 - index) * slot
    }

    private static func line(_ values: [CGFloat], in size: CGSize) -> Path {
        var path = Path()
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: x(index, count: values.count, width: size.width),
                                y: size.height - max(1, size.height * min(1, value)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
