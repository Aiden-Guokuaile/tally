import SwiftUI

/// 三页共用的排版件：卡片、键值行、压力条、页签、标题行按钮。面板底是纯黑，所有底色都是白的低透明度。
/// 配方照 Atoll：卡片圆角 12 + 发丝描边，数字 rounded 等宽，可点的东西悬停有底。
struct Card<Content: View>: View {
    let title: String?
    let symbol: String?
    let tint: Color
    let content: Content

    init(_ title: String? = nil, symbol: String? = nil, tint: Color = .white, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                HStack(spacing: 5) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
        )
    }
}

extension Font {
    /// 数字专用：rounded 字形 + 等宽数字。只用三档：17 粗、13 半粗、11。
    static func metric(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

/// 「键 …… 值」一行，值靠右、等宽数字。
struct KeyValueRow: View {
    let key: String
    let value: String
    /// 值的颜色，nil 就是普通白。
    var tint: Color? = nil

    var body: some View {
        HStack {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 8)
            Text(value)
                .font(.metric(11))
                .foregroundStyle(tint ?? .white.opacity(0.9))
                .lineLimit(1)
        }
    }
}

/// 一条压力指标：名字 + 进度条 + 数值。fraction 为 nil 时条是空的；level 为 nil 时条是中性色。
struct MetricBar: View {
    let name: String
    let fraction: Double?
    let level: SystemSample.Level?
    let text: String
    var textWidth: CGFloat = 150

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 34, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    if fraction != nil {
                        Capsule()
                            .fill(color)
                            .frame(width: max(4, geometry.size.width * min(1, max(0, fraction ?? 0))))
                    }
                }
            }
            .frame(height: 6)
            .animation(.smooth(duration: 0.25), value: fraction)
            Text(text)
                .font(.metric(11, .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: textWidth, alignment: .trailing)
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch level {
        case .critical: return .red
        case .warn: return .yellow
        case .ok: return .green
        case nil: return .white.opacity(0.5)
        }
    }
}

/// 页签：只有图标（照 Atoll），名字在悬停提示里；选中的胶囊底在页签之间滑过去；外面一层浅槽把它们框成一组。
/// 不带字是因为标题行左段只有 180pt 宽（中间要给刘海留空）：只放图标能放 6 颗，选中的带字就只能放 4 颗。
struct TabBar: View {
    let pages: [LaunchOptions.Page]
    let selected: LaunchOptions.Page
    let onSelect: (LaunchOptions.Page) -> Void
    @Namespace private var capsule

    var body: some View {
        HStack(spacing: 1) {
            ForEach(pages, id: \.self) { page in
                let isSelected = page == selected
                Button {
                    onSelect(page)
                } label: {
                    Image(systemName: page.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
                        .frame(width: 16)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(.white.opacity(0.18))
                                .matchedGeometryEffect(id: "selected", in: capsule)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(page.title)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.05)))
        .animation(.smooth(duration: 0.25), value: selected)
    }
}

/// 标题行右侧的图标按钮：悬停出胶囊底。
struct HeaderButton: View {
    let symbol: String
    let help: String
    var dimmed = false
    /// 开着的功能用它着色，nil 是普通白。
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint ?? .white.opacity(dimmed ? 0.3 : 0.7))
                .frame(width: 24, height: 22)
                .background(Capsule().fill(.white.opacity(hovered ? 0.12 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.smooth(duration: 0.2), value: hovered)
        .help(help)
    }
}

/// 提供方标志（Lobe Icons 的单色 SVG，MIT，见 NOTICE）：会话行标签和用量行名字前面用。
/// SVG 是 `currentColor` 单色，按模板图着色：Claude 用它自己的橙，其余白。随 app 打包在 Resources 里（`build-app.sh` 拷），
/// 读不到（比如 `swift run`、测试）就不画，不影响旁边的字。
struct ProviderLogo: View {
    /// 资源名：claude / openai / cursor / antigravity。
    let name: String
    var size: CGFloat = 11

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let image = Self.image(name) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .frame(width: size, height: size)
                .foregroundStyle(name == "claude" ? Color(red: 0.851, green: 0.467, blue: 0.341) : .white.opacity(0.85))
        }
    }

    private static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
