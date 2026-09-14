import SwiftUI

/// 面板根视图。闭合态纯黑（有事时垂提示条），展开态是标题行 + 页面。
struct NotchView: View {
    let state: NotchState
    var store = SessionStore.shared
    var usage = UsageStore.shared
    var privacy = PrivacyWatcher.shared
    var preferences = PreferencesStore.shared
    @State private var dropTargeted = false

    var body: some View {
        let waiting = store.waitingCount()
        ZStack(alignment: .top) {
            NotchShape(top: state.isOpen ? NotchGeometry.shoulder : 0,
                       bottom: state.isOpen ? NotchGeometry.openBottomRadius
                           : (state.peek != nil ? NotchGeometry.peekBottomRadius : NotchGeometry.closedBottomRadius))
                .fill(.black)
            if state.isOpen {
                openContent(waiting: waiting)
                    // 壳先撑开，内容晚 0.1 s 从模糊里浮出来；收起时直接淡掉，别在缩小的壳外面拖影
                    .transition(AsymmetricTransition(
                        insertion: BlurReplaceTransition(configuration: .downUp).animation(.smooth(duration: 0.3).delay(0.1)),
                        removal: OpacityTransition().animation(.easeOut(duration: 0.12))
                    ))
            } else if let peek = state.peek {
                // id 跟着提示走：新的一条重建视图，入场动画重放
                PeekContent(peek: peek, notchHeight: state.notchHeight, onWidth: { state.reportPeekContentWidth($0) }, onTap: { state.peekTapped?() })
                    .id(peek.id)
                    .transition(.opacity)
            }
            // 闭合态什么都不画：刘海正下方是摄像头外壳，没有像素，画了也看不见（截图却拍得到）
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 文件拖放挂在根上：闭合态拖到刘海就展开到文件架，展开态落到任何一页都收；开关关了不注册
        .onDrop(of: preferences.prefs.shelfEnabled ? ShelfDrop.types : [], isTargeted: $dropTargeted) { ShelfDrop.handle($0) }
        .onChange(of: dropTargeted) { _, targeted in
            if targeted { state.dropEntered?() }
        }
        // 圆角和窗口 frame 用同一条曲线、同一个时长，看起来才是一体的
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: state.isOpen ? 0.38 : 0.30), value: state.isOpen)
        .animation(.easeOut(duration: 0.2), value: state.peek?.id)
    }

    // MARK: 展开态

    private func openContent(waiting: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 三段：页签靠左、按钮靠右，中间给物理刘海留空，不然第四颗页签正好钻到刘海底下（照 Atoll 的标题行）
            HStack(spacing: 0) {
                TabBar(pages: LaunchOptions.Page.visible(shelf: preferences.prefs.shelfEnabled), selected: state.page) { state.select($0) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                // 定高：Color 在 HStack 里竖向也贪婪，不限高会把整个标题行撑到面板中间
                Color.clear
                    .frame(width: NotchGeometry.headerGap(closedWidth: state.notchWidth), height: 1)
                HStack(spacing: 6) {
                    if waiting > 0 {
                        WaitingBadge(count: waiting)
                    }
                    PrivacyDots(privacy: privacy)
                    if PreferencesStore.shared.prefs.keepAwakeButton {
                        KeepAwakeButton()
                    }
                    RefreshControl(page: state.page, usage: usage)
                    HeaderButton(symbol: "gearshape", help: "设置") { state.openSettings?() }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            // 内容比面板高时（代理组多）让它滚，不然 VStack 居中会把顶部裁掉。
            // 切页不做滑动过渡：窗口高度动画和页面滑动同时跑，每帧都要把新旧两页重新布局，曲线还不一样，看着卡。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    PageTitle(page: state.page)
                    pageContent
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { state.reportContentHeight($0) }
            }
        }
        .padding(.horizontal, NotchGeometry.shoulder + 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch state.page {
        case .ai, .settings:
            AIPage()
        case .network:
            NetworkPage()
        case .system:
            SystemPage()
        case .apps:
            AppsPage()
        case .shelf:
            ShelfPage()
        }
    }
}

/// 页标题：页签只有图标，页里补一行名字，右边跟一句活的摘要（会话几个在等、网速、内存、几个 app、几件文件）。
struct PageTitle: View {
    let page: LaunchOptions.Page
    var sessions = SessionStore.shared
    var network = NetworkStore.shared
    var system = SystemStore.shared
    var apps = RunningAppsStore.shared
    var shelf = ShelfStore.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(page.title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.95))
            Text(detail)
                .font(.metric(10, .regular))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private var detail: String {
        switch page {
        case .ai, .settings:
            // 已关闭的只是留着接着聊，不算「会话」
            return PageSummary.ai(sessions: sessions.sessions.filter { $0.state != .ended }.count, waiting: sessions.waitingCount())
        case .network:
            return PageSummary.network(interface: network.primary.map { $0.wifi == nil ? "有线 \($0.name)" : "Wi-Fi \($0.name)" },
                                       down: network.down.map(ByteFormat.rate), up: network.up.map(ByteFormat.rate))
        case .system:
            let s = system.sample
            let memory: String? = {
                guard let used = s.memoryUsed, let total = s.memoryTotal else { return nil }
                return SystemPage.pairText(ByteFormat.string(used), ByteFormat.string(total))
            }()
            return PageSummary.system(chip: system.hardware?.chip, memory: memory)
        case .apps:
            return PageSummary.apps(total: apps.apps.count, hidden: apps.apps.filter(\.isHidden).count)
        case .shelf:
            return PageSummary.shelf(count: shelf.items.count)
        }
    }
}

/// 页标题右边那句摘要，纯函数。
enum PageSummary {
    static func ai(sessions: Int, waiting: Int) -> String {
        guard sessions > 0 else { return "没有在跑的会话" }
        return waiting > 0 ? "\(sessions) 个会话 · \(waiting) 个在等你" : "\(sessions) 个会话"
    }

    static func network(interface: String?, down: String?, up: String?) -> String {
        var parts: [String] = []
        if let interface { parts.append(interface) }
        if let down, let up { parts.append("↓\(down) ↑\(up)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    static func system(chip: String?, memory: String?) -> String {
        var parts: [String] = []
        if let chip { parts.append(chip) }
        if let memory { parts.append("内存 \(memory)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    static func apps(total: Int, hidden: Int) -> String {
        guard total > 0 else { return "没有在跑的 app" }
        return hidden > 0 ? "\(total) 个在跑 · \(hidden) 个 Dock 里看不见" : "\(total) 个在跑"
    }

    static func shelf(count: Int) -> String {
        count > 0 ? "\(count) 项 · 保留 3 天" : "拖文件到刘海上暂存"
    }
}

/// 保持唤醒：点一下不限时开 / 关，右键选时长、切屏幕常亮。开着时杯子是实心橙色。
struct KeepAwakeButton: View {
    var keepAwake = KeepAwake.shared
    var preferences = PreferencesStore.shared

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        let keepDisplay = preferences.prefs.keepAwakeDisplay
        HeaderButton(symbol: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", help: help,
                     tint: keepAwake.isActive ? .orange : nil) {
            if keepAwake.isActive { keepAwake.stop() } else { keepAwake.start(minutes: nil, keepDisplay: keepDisplay) }
        }
        .contextMenu {
            // 时长项做成带勾的：Button 天生不显示状态，杯子亮着菜单里也一个勾都没有，看不出开没开、开的是哪档
            Toggle("一直保持唤醒", isOn: Binding(
                get: { keepAwake.isActive && keepAwake.until == nil },
                set: { on in
                    if on { keepAwake.start(minutes: nil, keepDisplay: keepDisplay) } else { keepAwake.stop() }
                }
            ))
            ForEach(KeepAwake.durations, id: \.self) { minutes in
                Toggle(KeepAwake.durationLabel(minutes), isOn: Binding(
                    get: { keepAwake.minutes == minutes },
                    set: { on in
                        if on { keepAwake.start(minutes: minutes, keepDisplay: keepDisplay) } else { keepAwake.stop() }
                    }
                ))
            }
            // 自定义档设过了才有这条；跟某个预设档撞上就不重复出一遍
            if let custom = preferences.prefs.keepAwakeCustomMinutes, !KeepAwake.durations.contains(custom) {
                Toggle(KeepAwake.durationLabel(custom), isOn: Binding(
                    get: { keepAwake.minutes == custom },
                    set: { on in
                        if on { keepAwake.start(minutes: custom, keepDisplay: keepDisplay) } else { keepAwake.stop() }
                    }
                ))
            }
            Divider()
            Toggle("屏幕也保持常亮", isOn: Binding(
                get: { preferences.prefs.keepAwakeDisplay },
                set: { on in
                    preferences.prefs.keepAwakeDisplay = on
                    keepAwake.setKeepsDisplay(on)
                }
            ))
            if keepAwake.isActive {
                Divider()
                Button("关闭") { keepAwake.stop() }
            }
        }
    }

    private var help: String {
        let mode = preferences.prefs.keepAwakeDisplay ? "屏幕常亮" : "允许熄屏"
        guard keepAwake.isActive else { return "保持唤醒 · \(mode)（右键选时长）" }
        if let until = keepAwake.until { return "保持唤醒到 \(Self.clock.string(from: until)) · \(mode)，点击关闭" }
        return "一直保持唤醒 · \(mode)，点击关闭"
    }
}

/// 刷新当前页：AI 页刷用量（「更新于 HH:mm」放在按钮的提示里，60 秒内刚刷过就在旁边提示两秒），其他页立刻重采一次。
struct RefreshControl: View {
    let page: LaunchOptions.Page
    var usage: UsageStore
    @State private var throttled = false

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 4) {
            if page == .ai, throttled {
                Text("60 秒内刚刷过")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            HeaderButton(symbol: "arrow.clockwise", help: help, dimmed: page == .ai && usage.isRefreshing, action: refresh)
                .disabled(page == .ai && usage.isRefreshing)
        }
    }

    private var help: String {
        guard page == .ai else { return "刷新这一页" }
        return usage.lastRefreshed.map { "刷新用量（更新于 " + Self.clock.string(from: $0) + "）" } ?? "刷新用量"
    }

    private func refresh() {
        switch page {
        case .ai, .settings:
            if usage.refresh(reason: .manual) {
                throttled = false
            } else if !usage.isRefreshing {
                throttled = true
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    throttled = false
                }
            }
        case .network: NetworkStore.shared.refreshNow()
        case .system: SystemStore.shared.refreshNow()
        case .apps: RunningAppsStore.shared.refreshNow()
        case .shelf: ShelfStore.shared.start()
        }
    }
}

/// 提示条：从刘海往下垂一条，上面 `notchHeight` 那段留给刘海，下面一行是着色图标 + 短标签 + 标题 / 副标题。
/// 入场：图标从中心弹出（欠阻尼弹簧）并向外扩一圈涟漪，文字从刘海底下往下滑出来，副标题晚一拍；图标按 `style` 各有动作。
struct PeekContent: View {
    let peek: Peek
    let notchHeight: CGFloat
    /// 内容量出来的自然宽度，面板宽度跟着它收紧。
    let onWidth: (CGFloat) -> Void
    let onTap: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 8) {
                PeekIcon(peek: peek, appeared: appeared)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(peek.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(peek.tint)
                        Text(peek.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : -8)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.1), value: appeared)
                    if let subtitle = peek.subtitle {
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.55))
                            .opacity(appeared ? 1 : 0)
                            .offset(y: appeared ? 0 : -8)
                            .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.2), value: appeared)
                    }
                }
                .lineLimit(1)
            }
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { onWidth($0) }
            .frame(maxWidth: NotchGeometry.peekMaxWidth - 2 * NotchGeometry.peekPadding, alignment: .leading)
            .padding(.horizontal, NotchGeometry.peekPadding)
            .frame(height: NotchGeometry.peekDrop)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // 只有会话类可点：电池类挂着手势就成了「点一下提早收起」，文档说它不可点
        .allowsHitTesting(peek.sessionId != nil)
        .onAppear { appeared = true }
    }
}

/// 提示条左边的图标：着色圆角块 + 一圈涟漪，里面按类型动——
/// 会话完成先画圆环再勾一下、随后撒一把彩纸；接电闪电向上弹再脉动；拔电插头往下弹；低电脉动加轻晃；充满弹一下并撒星星。
private struct PeekIcon: View {
    let peek: Peek
    let appeared: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(peek.tint.opacity(0.4))
                .frame(width: 24, height: 24)
                .scaleEffect(appeared ? 2.6 : 0.5)
                .opacity(appeared ? 0 : 0.9)
                .animation(.easeOut(duration: 0.8).delay(0.1), value: appeared)
            if peek.style == .session {
                Confetti(appeared: appeared)
            }
            RoundedRectangle(cornerRadius: 7)
                .fill(peek.tint.opacity(0.16))
                .frame(width: 24, height: 24)
            glyph
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(peek.tint)
        }
        .frame(width: 24, height: 24)
        .scaleEffect(appeared ? 1 : 0.3)
        .animation(.spring(response: 0.42, dampingFraction: 0.55), value: appeared)
    }

    @ViewBuilder
    private var glyph: some View {
        switch peek.style {
        case .session:
            CheckRing(tint: peek.tint, appeared: appeared)
        case .ask:
            Image(systemName: peek.label == "等输入" ? "questionmark" : "exclamationmark")
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
                .symbolEffect(.pulse, options: .repeating.speed(1.2))
        case .pluggedIn:
            Image(systemName: "bolt.fill")
                .symbolEffect(.bounce.up, options: .nonRepeating, value: appeared)
                .symbolEffect(.pulse, options: .repeating.speed(0.8))
        case .unplugged:
            Image(systemName: "powerplug.fill")
                .symbolEffect(.bounce.down, options: .nonRepeating, value: appeared)
        case .low:
            Image(systemName: "battery.25percent")
                .symbolEffect(.pulse, options: .repeating.speed(1.4))
                .symbolEffect(.wiggle, options: .repeating.speed(0.6))
        case .quotaHigh:
            Image(systemName: "gauge.with.dots.needle.67percent")
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
        case .quotaExhausted:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolEffect(.pulse, options: .repeating.speed(1.2))
        case .quotaReset:
            Image(systemName: "arrow.clockwise")
                .symbolEffect(.rotate, options: .nonRepeating, value: appeared)
        case .shelf:
            Image(systemName: "tray.and.arrow.down.fill")
                .symbolEffect(.bounce.down, options: .nonRepeating, value: appeared)
        case .update:
            Image(systemName: "arrow.down.circle.fill")
                .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
        case .full:
            ZStack {
                Image(systemName: "battery.100percent")
                    .symbolEffect(.bounce, options: .nonRepeating, value: appeared)
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.yellow)
                    .offset(x: 8, y: -7)
                    .scaleEffect(appeared ? 1 : 0.2)
                    .opacity(appeared ? 1 : 0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.5).delay(0.3), value: appeared)
            }
        }
    }
}

/// 会话完成的勾：圆环先画满（0.35 s），再把勾从左到右画出来。
private struct CheckRing: View {
    let tint: Color
    let appeared: Bool

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: appeared ? 1 : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35).delay(0.1), value: appeared)
            CheckShape()
                .trim(from: 0, to: appeared ? 1 : 0)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .animation(.easeOut(duration: 0.25).delay(0.4), value: appeared)
        }
        .frame(width: 15, height: 15)
    }
}

/// 一把彩纸：十二片小纸片从图标中心飞出、边转边淡，勾画完之后才撒。角度和距离按序号定，不用随机数，每次一样好看。
private struct Confetti: View {
    let appeared: Bool
    private static let colors: [Color] = [.green, .yellow, .orange, .pink, .cyan, .mint]

    var body: some View {
        ZStack {
            ForEach(0..<12, id: \.self) { index in
                let angle = Double(index) * 30 + (index.isMultiple(of: 2) ? 8 : -8)
                let distance: CGFloat = index.isMultiple(of: 3) ? 30 : 22
                RoundedRectangle(cornerRadius: 1)
                    .fill(Self.colors[index % Self.colors.count])
                    .frame(width: 4, height: index.isMultiple(of: 2) ? 6 : 4)
                    .rotationEffect(.degrees(appeared ? angle * 3 : 0))
                    .offset(x: appeared ? cos(angle * .pi / 180) * distance : 0,
                            y: appeared ? sin(angle * .pi / 180) * distance : 0)
                    .opacity(appeared ? 0 : 1)
                    .animation(.easeOut(duration: 0.9).delay(0.55 + Double(index) * 0.02), value: appeared)
            }
        }
    }
}

/// 一个勾的折线，按单位矩形定点。
private struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.54))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.72))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.32))
        return path
    }
}

/// 摄像头绿、麦克风橙：被别的进程占用时才画。
struct PrivacyDots: View {
    var privacy: PrivacyWatcher

    var body: some View {
        if privacy.cameraInUse {
            Image(systemName: "video.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
                .help("摄像头使用中")
        }
        if privacy.microphoneInUse {
            Image(systemName: "mic.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.orange)
                .help("麦克风使用中")
        }
    }
}

/// 橙点加数字：有会话在等我。
struct WaitingBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.orange)
                .frame(width: 8, height: 8)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.orange)
        }
    }
}

/// 刘海形状（路径照 Atoll 的 `NotchShape`）：顶角是向外翻的肩部弧线，让黑块像从屏幕边缘长出来；底角圆角。
/// 竖边向内缩 `top`，所以展开态肩部占掉两侧各 `top` 的宽度。两个半径都能动画，随开合插值。
struct NotchShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let top = min(self.top, rect.height / 2)
        let bottom = min(self.bottom, rect.height / 2, rect.width / 2 - top)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                          control: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                          control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
