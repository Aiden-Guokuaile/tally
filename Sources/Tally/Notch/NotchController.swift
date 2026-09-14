import AppKit
import Carbon.HIToolbox
import SwiftUI
import Observation

/// 面板的展示状态，SwiftUI 视图直接观察它。
@MainActor
@Observable
final class NotchState {
    var isOpen = false
    /// `--open` 启动时为 true：不因鼠标离开或点外收起，直到再点一次刘海。
    var isPinned = false
    var page: LaunchOptions.Page = .ai
    /// 闭合态刘海宽高：标题行按宽在中间留空，提示条按高把内容排在刘海下面。
    var notchWidth: CGFloat = 189
    var notchHeight: CGFloat = 32
    /// 闭合态正在弹的提示；nil 就是普通闭合态。
    var peek: Peek?
    /// 提示条内容量出来的宽度，面板宽度跟着它收紧。
    var peekContentWidth: CGFloat = 0
    var peekContentWidthChanged: (() -> Void)?
    /// 点了提示条：会话类的跳回终端。
    var peekTapped: (() -> Void)?

    func reportPeekContentWidth(_ width: CGFloat) {
        guard abs(width - peekContentWidth) > 0.5 else { return }
        peekContentWidth = width
        peekContentWidthChanged?()
    }

    /// 当前页内容的自然高度，页视图量了报上来；面板高度跟着它走。
    var contentHeight: CGFloat = 0
    var contentHeightChanged: (() -> Void)?
    /// 齿轮按钮和右键菜单的「设置…」都走这里，由 AppDelegate 接上设置窗口。
    var openSettings: (() -> Void)?
    /// 有文件拖到面板上（闭合或展开都算），控制器据此展开 / 切到文件架。
    var dropEntered: (() -> Void)?
    /// 展开着切页签时通知控制器换采样对象。
    var pageChanged: ((_ from: LaunchOptions.Page, _ to: LaunchOptions.Page) -> Void)?

    func reportContentHeight(_ height: CGFloat) {
        guard abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        contentHeightChanged?()
    }

    /// 点页签：记住它，展开着就换采样。
    func select(_ next: LaunchOptions.Page) {
        let previous = page
        page = next
        PreferencesStore.shared.prefs.lastPage = next.rawValue
        if isOpen, previous != next { pageChanged?(previous, next) }
    }
}

/// 点提示条时做什么。落盘存 rawValue，认不出的回落到默认（跳回对应终端）。
enum PeekTapAction: String, CaseIterable {
    case terminal, ai, both

    var label: String {
        switch self {
        case .terminal: return "跳回对应终端"
        case .ai: return "展开到 AI 页"
        case .both: return "两者都要"
        }
    }

    static func parse(_ raw: String) -> PeekTapAction { PeekTapAction(rawValue: raw) ?? .terminal }
}

/// 闭合态提示条里的内容：着色图标 + 短标签 + 标题 + 副标题。会话事件和电池事件都走它；`style` 决定图标怎么动，`sessionId` 非空时可点。
struct Peek: Equatable {
    enum Style { case session, ask, pluggedIn, unplugged, low, full, quotaHigh, quotaExhausted, quotaReset, shelf, update }

    var id: String
    var style: Style
    var tint: Color
    var label: String
    var title: String
    var subtitle: String?
    var sessionId: String?

    /// 等审批比跑完多留这么久：真要人来的那种该多给点时间。原来两档写死 8 和 5，差值就是它。
    static let askExtra: TimeInterval = 3

    /// 停留多久。两个秒数从设置来（`peekSessionSeconds` / `peekBatterySeconds`），纯函数好测。
    func duration(session: Int, battery: Int) -> TimeInterval {
        switch style {
        case .ask: return TimeInterval(session) + Self.askExtra
        case .session, .quotaHigh, .quotaExhausted, .quotaReset, .update: return TimeInterval(session)
        default: return TimeInterval(battery)
        }
    }

    /// 没有刘海屏时改发系统通知的那几种：电池的不发，系统自己会说。
    var notifiesWithoutNotch: Bool { priority > 0 }

    /// 抢占顺序：等你 > 跑完 > 配额、文件架 > 电池。低的不顶掉正挂着的高的（`PeekQueue`）。
    var priority: Int {
        switch style {
        case .ask: return 3
        case .session: return 2
        case .quotaHigh, .quotaExhausted, .quotaReset, .shelf, .update: return 1
        case .pluggedIn, .unplugged, .low, .full: return 0
        }
    }

    /// 会话类提示条挂着时不许按悬停展开：`open()` 头一件事就是 `clearPeek()`，
    /// 而人从光标落到提示条上到按下鼠标要 200–400 ms，150 ms 的悬停定时器一定抢在前面，
    /// 提示条被清掉，点击落到展开态标题行的空位上——「点了没反应」就是这么来的。
    /// 电池类不拦：拦了悬停展开要被堵住整整一条提示条的时间。
    static func holdsHoverOpen(_ peek: Peek?) -> Bool { peek?.sessionId != nil }

    /// 点一下要干的事。电池类不可点，给个空计划。
    struct TapPlan: Equatable {
        var focusTerminal = false
        var openAI = false
    }

    func tapPlan(_ action: PeekTapAction) -> TapPlan {
        guard sessionId != nil else { return TapPlan() }
        switch action {
        case .terminal: return TapPlan(focusTerminal: true)
        case .ai: return TapPlan(openAI: true)
        case .both: return TapPlan(focusTerminal: true, openAI: true)
        }
    }

    /// 估一个宽度给第一帧用，量出实际宽度后控制器再收紧：中文按 11pt、其余按 6.5pt 一个字。
    var estimatedContentWidth: CGFloat {
        func width(_ text: String) -> CGFloat {
            text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 11 : 6.5) }
        }
        let top = width(label) + 5 + width(title)
        let bottom = subtitle.map(width) ?? 0
        return 24 + 8 + max(top, bottom)
    }

    /// 会话跑完（绿勾）或在等我（橙色叹号 / 问号）。
    static func session(_ record: SessionRecord) -> Peek {
        let id = "session-\(record.sessionId)-\(record.state.rawValue)-\(record.updatedAt)"
        switch record.state {
        case .waitingPermission:
            return Peek(id: id, style: .ask, tint: .orange, label: "等审批", title: record.displayTitle, subtitle: "\(record.providerLabel) 在等你点一下 · 点这里跳过去", sessionId: record.sessionId)
        case .waitingInput:
            return Peek(id: id, style: .ask, tint: .yellow, label: "等输入", title: record.displayTitle, subtitle: "\(record.providerLabel) 有话问你 · 点这里跳过去", sessionId: record.sessionId)
        default:
            return Peek(id: id, style: .session, tint: .green, label: record.providerLabel, title: record.displayTitle,
                        subtitle: record.message.flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "\n", with: " ") } ?? "跑完了 · 点这里跳过去",
                        sessionId: record.sessionId)
        }
    }

    /// 配额涨过 80%（橙）、用完（红）、重置（绿）。不可点。
    static func quota(_ event: QuotaEvent, now: Date = Date()) -> Peek {
        let id = "quota-\(event.provider.rawValue)-\(event.window)-\(Int(now.timeIntervalSince1970 * 1000))"
        let title = "\(event.provider.displayName) · \(event.window)"
        let reset = ResetLabel.text(for: event.resetsAt, now: now)
        switch event.kind {
        case .high(let percent):
            return Peek(id: id, style: .quotaHigh, tint: .orange, label: "配额 \(percent)%", title: title,
                        subtitle: ["已用 \(percent)%", reset].compactMap { $0 }.joined(separator: " · "))
        case .exhausted:
            return Peek(id: id, style: .quotaExhausted, tint: .red, label: "配额用完", title: title,
                        subtitle: ["用完了", reset].compactMap { $0 }.joined(separator: " · "))
        case .reset:
            return Peek(id: id, style: .quotaReset, tint: .green, label: "配额重置", title: title, subtitle: "重置了，又能用了")
        }
    }

    /// 有新版本。不可点：brew 装的直接给升级命令，别的指到设置里的下载按钮。
    static func update(_ version: String) -> Peek {
        Peek(id: "update-\(version)", style: .update, tint: .blue, label: "有新版本", title: "Tally \(version)",
             subtitle: UpdateChecker.installedByHomebrew() ? "brew upgrade --cask tally" : "设置 → 通用 里下载")
    }

    /// `open -a Tally <文件>` 放进文件架。不可点；文件架关着就说一声，不偷偷打开开关。
    static func shelf(names: [String], enabled: Bool, now: Date = Date()) -> Peek {
        let id = "shelf-\(Int(now.timeIntervalSince1970 * 1000))"
        let title = names.count == 1 ? names[0] : "\(names.count) 个文件"
        guard enabled else {
            return Peek(id: id, style: .shelf, tint: .orange, label: "文件架没开", title: title, subtitle: "设置 → 文件架 打开后再放")
        }
        return Peek(id: id, style: .shelf, tint: .mint, label: "放进文件架", title: title, subtitle: "展开面板到文件架取用")
    }

    /// 电源文案：把电池当成一个会说话的小家伙。
    static func battery(_ event: BatteryEvent, now: Date = Date()) -> Peek {
        let id = "battery-\(Int(now.timeIntervalSince1970 * 1000))"
        switch event {
        case .pluggedIn(let percent):
            return Peek(id: id, style: .pluggedIn, tint: .green, label: "续命成功", title: "\(percent)%", subtitle: "电池：谢谢投喂")
        case .unplugged(let percent):
            return Peek(id: id, style: .unplugged, tint: .yellow, label: "断奶了", title: "\(percent)%",
                        subtitle: percent >= 50 ? "电池：靠自己了，问题不大" : "电池：靠自己了，有点虚")
        case .low(let percent, let threshold):
            return Peek(id: id, style: .low, tint: threshold <= 10 ? .red : .orange, label: threshold <= 10 ? "要昏了" : "饿了",
                        title: "\(percent)%", subtitle: threshold <= 10 ? "电池：救命" : "电池：给口吃的")
        case .full:
            return Peek(id: id, style: .full, tint: .green, label: "吃饱了", title: "100%", subtitle: "电池：拔吧，撑着了")
        }
    }
}

/// 新提示来时怎么排，纯函数。不然一条电池提示能把「等输入」顶掉，人就错过了。
enum PeekQueue {
    enum Decision: Equatable { case show, wait }

    /// 没有正挂着的、比它高、或是同一个会话的新状态（等输入之后跑完了，不留过时的那条）→ 马上换上；否则排队。
    /// 一样高也排队：两个会话前后脚都在等审批，后来的顶掉先来的，先来的那个就再没人提醒了。
    static func decide(incoming: Peek, showing: Peek?) -> Decision {
        guard let showing else { return .show }
        if incoming.sessionId != nil, incoming.sessionId == showing.sessionId { return .show }
        return incoming.priority > showing.priority ? .show : .wait
    }

    /// 队里只留一条：留优先级高的，一样高留新的。
    static func keep(_ incoming: Peek, over pending: Peek?) -> Peek {
        guard let pending, pending.priority > incoming.priority else { return incoming }
        return pending
    }
}

/// 刘海面板的生命周期：定位、悬停展开、点外收起、右键菜单、屏幕变化。
@MainActor
final class NotchController {

    let state = NotchState()

    private let panel: NotchPanel
    private let hostView: NotchHostView
    private var metrics: ScreenMetrics?
    private var openTimer: Timer?
    private var closeTimer: Timer?
    /// 展开期间每 100 ms 看一次光标还在不在面板上。
    private var hoverPoll: Timer?
    /// 上次收起的时刻：收起动画里 AppKit 会按过期的追踪矩形合成一次进入事件，刚收起的 400 ms 内不理。
    private var closedAt = Date.distantPast
    /// 面板在光标脚下缩小之前的 frame：切到矮的页时光标会突然落在面板外，还在这块老区域里就不算离开。
    private var shrunkFrom: CGRect?
    private var peekTimer: Timer?
    /// 被正挂着的高优先级提示挡住、等它收回再垂的那一条。
    private var pendingPeek: Peek?
    private var outsideClickMonitor: Any?
    private var gestureMonitor: Any?
    private var keyMonitor: Any?
    private var swipe = SwipeTracker()

    init(openOnLaunch: LaunchOptions.Page?, openSettings: @escaping () -> Void) {
        state.openSettings = openSettings
        panel = NotchPanel(contentRect: CGRect(origin: .zero, size: CGSize(width: NotchGeometry.openWidth, height: NotchGeometry.minOpenHeight)))
        hostView = NotchHostView(rootView: NotchView(state: state))
        hostView.autoresizingMask = [.width, .height]
        panel.contentView = hostView

        hostView.onMouseEntered = { [weak self] in self?.hoverStarted() }
        hostView.onMouseExited = { [weak self] in self?.hoverEnded() }
        hostView.onLeftClick = { [weak self] point in self?.clickedInside(at: point) }
        hostView.onRightClick = { [weak self] point in self?.showMenu(at: point) }
        hostView.isPanelOpen = { [weak self] in self?.state.isOpen ?? false }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.relayout() }
        }

        state.pageChanged = { [weak self] previous, next in
            self?.stopSampling(for: previous)
            self?.startSampling(for: next)
        }
        // 文件拖到刘海上：闭合就展开到文件架，开着就切到文件架；落下的文件由 ShelfDrop 收
        state.dropEntered = { [weak self] in
            guard let self, PreferencesStore.shared.prefs.shelfEnabled else { return }
            if !self.state.isOpen {
                self.state.page = .shelf
                self.open()
            } else if self.state.page != .shelf {
                self.state.select(.shelf)
            }
        }
        state.contentHeightChanged = { [weak self] in
            guard let self, self.state.isOpen else { return }
            self.applyFrame(animated: true)
        }
        SessionStore.shared.sessionAlert = { [weak self] record in Task { await self?.sessionAlerted(record) } }
        UsageStore.shared.quotaAlert = { [weak self] event in
            guard PreferencesStore.shared.prefs.quotaPeek else { return }
            self?.showPeek(.quota(event))
        }
        state.peekContentWidthChanged = { [weak self] in
            guard let self, !self.state.isOpen, self.state.peek != nil else { return }
            self.applyFrame(animated: true)
        }
        state.peekTapped = { [weak self] in self?.peekTapped() }
        BatteryWatcher.shared.onEvent = { [weak self] event in self?.showPeek(.battery(event)) }
        ScreenshotWatcher.shared.onScreenshots = { [weak self] urls in self?.receiveFiles(urls) }
        // 同一个版本只在刘海里说一次；设置「通用」那一行一直在
        UpdateChecker.shared.onNewVersion = { [weak self] release in
            guard PreferencesStore.shared.prefs.updateNotifiedVersion != release.version else { return }
            PreferencesStore.shared.prefs.updateNotifiedVersion = release.version
            self?.showPeek(.update(release.version))
        }
        SystemNotifier.shared.onTapSession = { sessionId in
            guard let session = SessionStore.shared.sessions.first(where: { $0.sessionId == sessionId }) else { return }
            Task { await SessionJump.shared.run(session) }
        }
        HotKeyCenter.shared.setHandler { [weak self] in self?.toggle() }
        HotKeyCenter.shared.setEnabled(PreferencesStore.shared.prefs.hotKeyEnabled)
        PreferencesStore.shared.onChange = { [weak self] in self?.applyPreferences() }
        applyPreferences()

        relayout()
        if let page = openOnLaunch {
            state.page = page
            open(pinned: true)
        } else {
            let last = LaunchOptions.Page(rawValue: PreferencesStore.shared.prefs.lastPage) ?? .ai
            state.page = last == .shelf && !PreferencesStore.shared.prefs.shelfEnabled ? .ai : last
        }
    }

    // MARK: 功能开关

    /// 按设置起停各功能，幂等：关掉的不起监听、不占内存。
    func applyPreferences() {
        let prefs = PreferencesStore.shared.prefs
        // 截屏和共享屏幕时隐藏：窗口服务器层面不给别的进程读这个窗口
        panel.sharingType = prefs.hideFromCapture ? .none : .readOnly
        BatteryWatcher.shared.setEnabled(prefs.batteryPeek)
        PrivacyWatcher.shared.setEnabled(prefs.privacyDots)
        ShelfStore.shared.setEnabled(prefs.shelfEnabled)
        if !prefs.shelfEnabled, state.page == .shelf { state.select(.ai) }
        if !prefs.keepAwakeButton { KeepAwake.shared.stop() }
        UpdateChecker.shared.setEnabled(prefs.checkUpdates)
        if prefs.shelfEnabled, prefs.screenshotsToShelf, let folder = prefs.screenshotFolder {
            ScreenshotWatcher.shared.start(folder: URL(fileURLWithPath: folder, isDirectory: true))
        } else {
            ScreenshotWatcher.shared.stop()
        }
        // 集合行为对已经在屏幕上的窗口要重新上屏才生效；没有刘海屏时面板本来就不在屏上，不去叫它出来
        if panel.setShowsInFullScreen(!prefs.hideInFullScreen), metrics != nil { panel.orderFrontRegardless() }
    }

    // MARK: 定位

    /// 重新找内建屏；找不到就把面板收起来。
    func relayout() {
        guard let screen = NotchGeometry.builtInNotchScreen() else {
            // 合盖或只剩外接屏：按收起处理，网络 / 系统的采样跟着停，不能只把窗口藏起来
            close()
            metrics = nil
            panel.orderOut(nil)
            Log.debug("没有带刘海的内建屏，面板隐藏")
            return
        }
        metrics = ScreenMetrics(screen: screen)
        if let metrics, let closed = NotchGeometry.closedSize(metrics) {
            state.notchWidth = closed.width
            state.notchHeight = closed.height
        }
        applyFrame(animated: false)
        panel.orderFrontRegardless()
    }

    private func applyFrame(animated: Bool) {
        guard let metrics, let closed = NotchGeometry.closedSize(metrics) else { return }
        let size: CGSize
        if state.isOpen {
            size = CGSize(width: NotchGeometry.openWidth,
                          height: NotchGeometry.openHeight(content: state.contentHeight, screenHeight: metrics.frame.height))
        } else if let peek = state.peek {
            size = NotchGeometry.peekSize(closed: closed, content: state.peekContentWidth > 0 ? state.peekContentWidth : peek.estimatedContentWidth)
        } else {
            size = closed
        }
        let frame = NotchGeometry.frame(for: size, on: metrics)
        if state.isOpen, frame.height < panel.frame.height - 0.5 {
            shrunkFrom = panel.frame
        }
        if animated {
            // 开合用 expo-out（起步快、收尾软，接近 Atoll 的临界阻尼弹簧；NSAnimationContext 只吃 timing function）；
            // 展开着只是换页或内容增减，高度小幅变化用短的 easeOut，长动画每帧重排 SwiftUI 会卡
            let heightOnly = state.isOpen && abs(frame.width - panel.frame.width) < 0.5
            NSAnimationContext.runAnimationGroup { context in
                context.duration = heightOnly ? 0.2 : (state.isOpen ? 0.38 : 0.30)
                context.timingFunction = heightOnly ? CAMediaTimingFunction(name: .easeOut) : CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }

    // MARK: 展开 / 收起

    func open(pinned: Bool = false) {
        openTimer?.invalidate()
        closeTimer?.invalidate()
        closeTimer = nil
        // 置空而不只是作废：触发过的定时器还挂在变量上，下面轮询的「还没排收起」判断（== nil）就再也不成立
        closeTimer = nil
        // 已经展开就什么都不做：悬停定时器晚 150 毫秒才触发，不能把 ⌥⇧T 刚钉住的面板改回不钉
        guard !state.isOpen else { return }
        clearPeek()
        state.isPinned = pinned
        state.isOpen = true
        applyFrame(animated: true)
        panel.makeKeyAndOrderFront(nil)
        installOutsideClickMonitor()
        installGestureMonitor()
        installKeyMonitor()
        startHoverPoll()
        UsageStore.shared.refresh(reason: .panelOpened)
        startSampling(for: state.page)
    }

    /// ⌥⇧T：收起就钉住展开（页是当前 `state.page`），展开（钉住或悬停）就收起。
    func toggle() {
        if state.isOpen { close() } else { open(pinned: true) }
    }

    func close() {
        openTimer?.invalidate()
        closeTimer?.invalidate()
        state.isPinned = false
        guard state.isOpen else { return }
        state.isOpen = false
        closedAt = Date()
        shrunkFrom = nil
        hoverPoll?.invalidate()
        hoverPoll = nil
        removeOutsideClickMonitor()
        removeGestureMonitor()
        removeKeyMonitor()
        SessionJump.shared.shortcutHints = false
        // open() 里 makeKey 之后键盘焦点归 Tally 进程（非激活面板不激活也能收键盘）；不交还的话面板缩回刘海了，
        // 之后打的字照样全进它，直到用户点一下别处。探针实测 resignKey 能把焦点还给原来的 app，再 makeKey 照常拿回
        if panel.isKeyWindow { panel.resignKey() }
        applyFrame(animated: true)
        NetworkStore.shared.stop()
        SystemStore.shared.stop()
        RunningAppsStore.shared.stop()
        ShelfStore.shared.stop()
    }

    // MARK: 完成提示

    /// 面板闭合时弹提示：提示条垂下几秒再收回（时长 `Peek.duration(session:battery:)`，秒数在设置里）；
    /// 连着来按 `PeekQueue` 排：比正挂着的高就换成新的并重新计时，一样高或更低的等它收回再垂。
    private func showPeek(_ peek: Peek) {
        guard !state.isOpen else { return }
        // 没有刘海屏（合盖接外接屏）提示条画不出来：改发系统通知，不然会话提醒只剩一声响
        guard metrics != nil else {
            if PreferencesStore.shared.prefs.notifyWithoutNotch, peek.notifiesWithoutNotch { SystemNotifier.shared.post(peek) }
            return
        }
        guard PeekQueue.decide(incoming: peek, showing: state.peek) == .show else {
            pendingPeek = PeekQueue.keep(peek, over: pendingPeek)
            return
        }
        peekTimer?.invalidate()
        state.peekContentWidth = 0
        state.peek = peek
        applyFrame(animated: true)
        let prefs = PreferencesStore.shared.prefs
        let seconds = peek.duration(session: prefs.peekSessionSeconds, battery: prefs.peekBatterySeconds)
        peekTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.peek != nil else { return }
                let heldHover = Peek.holdsHoverOpen(self.state.peek)
                // clearPeek 会连队里那条一起丢，先取出来
                let next = self.pendingPeek
                self.clearPeek()
                if let next {
                    self.showPeek(next)
                } else {
                    self.applyFrame(animated: true)
                }
                // 提示条挂着时拦下了悬停展开，收回这一刻光标还在面板上就补一次：
                // 追踪区只在光标真正跨界时发 mouseEntered，光标不动就再也不发了
                if heldHover, !Peek.holdsHoverOpen(self.state.peek), self.panel.frame.contains(NSEvent.mouseLocation) { self.hoverStarted() }
            }
        }
    }

    /// `open -a Tally <文件>`：照拖进来一样复制进文件架，闭合态弹一下说放了什么。
    func receiveFiles(_ urls: [URL]) {
        let enabled = PreferencesStore.shared.prefs.shelfEnabled
        showPeek(.shelf(names: urls.map(\.lastPathComponent), enabled: enabled))
        guard enabled else { return }
        Task { await ShelfStore.shared.add(urls: urls) }
    }

    /// 会话提示：那个会话的终端标签就在前台时不响也不弹（人正看着它）；不然按设置响一声，再垂提示条。
    private func sessionAlerted(_ record: SessionRecord) async {
        guard !state.isOpen else { return }
        if await SessionFrontmost.check(record) { return }
        if PreferencesStore.shared.prefs.sessionSound { AlertSound.play(for: record.state) }
        showPeek(.session(record))
    }

    /// 连队里那条一起丢：展开面板、点了提示条，人已经在看了，过会儿再垂一条旧消息只会添乱。
    private func clearPeek() {
        peekTimer?.invalidate()
        peekTimer = nil
        pendingPeek = nil
        state.peek = nil
        state.peekContentWidth = 0
    }

    /// 点提示条：按设置里的「点提示条时」三选一，提示条一律收起。
    private func peekTapped() {
        guard let peek = state.peek else { return }
        let plan = peek.tapPlan(PeekTapAction.parse(PreferencesStore.shared.prefs.peekTapAction))
        // open() 头一件事是 clearPeek()，要用的东西必须先取出来
        let session = peek.sessionId.flatMap { id in SessionStore.shared.sessions.first { $0.sessionId == id } }
        clearPeek()
        if plan.openAI {
            // 钉住：人是特意点过来看的，不钉的话手一挪面板就收了
            state.select(.ai)
            open(pinned: true)
        } else {
            applyFrame(animated: true)
        }
        guard plan.focusTerminal, let session else { return }
        // 脚本在后台跑，提示条不等它（第一次跳会弹自动化授权框）
        Task {
            do {
                try await TerminalLocator.focus(session: session)
            } catch {
                Log.error("从提示条跳回终端失败: \(error)")
            }
        }
    }

    /// 网络、系统、应用三页的采样只在面板展开且停在那页时跑。
    private func startSampling(for page: LaunchOptions.Page) {
        switch page {
        case .network: NetworkStore.shared.start()
        case .system: SystemStore.shared.start()
        case .apps: RunningAppsStore.shared.start()
        case .shelf: ShelfStore.shared.start()
        default: break
        }
    }

    private func stopSampling(for page: LaunchOptions.Page) {
        switch page {
        case .network: NetworkStore.shared.stop()
        case .system: SystemStore.shared.stop()
        case .apps: RunningAppsStore.shared.stop()
        case .shelf: ShelfStore.shared.stop()
        default: break
        }
    }

    /// 追踪区只在闭合态可信：窗口动画期间它的矩形是过期的（`updateTrackingAreas` 要到动画结束才被调用），
    /// AppKit 拿闭合态的矩形比对已经长大的窗口，会合成光标明明在面板上的离开事件。所以展开后改为轮询。
    private func hoverStarted() {
        guard PreferencesStore.shared.prefs.hoverToOpen, !state.isOpen, Date().timeIntervalSince(closedAt) > 0.4 else { return }
        // 会话提示条挂着就别展开：展开会把它清掉，人还没来得及点
        guard !Peek.holdsHoverOpen(state.peek) else { return }
        openTimer?.invalidate()
        openTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.open() }
        }
    }

    private func hoverEnded() {
        guard !state.isOpen else { return }
        openTimer?.invalidate()
    }

    /// 展开期间每 100 ms 看一次光标：离开面板 frame 满 150 ms 就收起（Atoll 是 100 ms），中途回来就作废。
    /// 鼠标按着的时候不收：那是在拖文件（拖进来或从文件架拖出去），光标必然要离开面板，收起会把拖拽掐断。
    private func startHoverPoll() {
        hoverPoll?.invalidate()
        hoverPoll = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.isOpen, !self.state.isPinned else { return }
                let dragging = NSEvent.pressedMouseButtons & 1 != 0
                let mouse = NSEvent.mouseLocation
                let verdict = HoverGrace.judge(mouse: mouse, frame: self.panel.frame, shrunkFrom: self.shrunkFrom)
                self.shrunkFrom = verdict.keepGrace ? self.shrunkFrom : nil
                if dragging || verdict.inside {
                    self.closeTimer?.invalidate()
                    self.closeTimer = nil
                } else if self.closeTimer == nil {
                    self.closeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                        Task { @MainActor in self?.close() }
                    }
                }
            }
        }
    }

    /// 钉住展开时，再点一次刘海才收起。面板里每次左键都会走到这里（页签、按钮、页内容也是），所以按位置判。
    private func clickedInside(at point: NSPoint) {
        guard state.isPinned,
              NotchGeometry.hitsNotch(point, panelSize: panel.frame.size,
                                      notch: CGSize(width: state.notchWidth, height: state.notchHeight)) else { return }
        close()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        // 全局监听只收别的 app 的点击，自己面板里的点击不会进来，正好就是「点外」。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.state.isPinned else { return }
                self.close()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: 手势翻页

    /// 用本地监视器而不是在视图里重写 scrollWheel：SwiftUI 的列表会把滚动事件吃掉，
    /// 监视器在分发之前就看得到；事件原样返回，列表照常竖着滚。只在展开期间挂着。
    private func installGestureMonitor() {
        guard gestureMonitor == nil else { return }
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .swipe]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let direction: SwipeTracker.Direction?
            if event.type == .swipe {
                direction = SwipeTracker.direction(fromSwipeDeltaX: event.deltaX)
            } else {
                direction = self.swipe.feed(phase: event.phase, deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY)
            }
            if let direction { self.turnPage(direction) }
            return event
        }
    }

    private func removeGestureMonitor() {
        if let monitor = gestureMonitor {
            NSEvent.removeMonitor(monitor)
            gestureMonitor = nil
        }
    }

    // MARK: 面板展开时的键盘

    /// 面板是 key window 但 app 不激活，主菜单的 ⌘, 收不到；展开期间自己接，顺带接数字键切页签、⌘1–⌘5 跳会话。
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let prefs = PreferencesStore.shared.prefs
            if event.type == .flagsChanged {
                // 按住 ⌘ 时会话行尾浮出 ⌘1–⌘5，松开消失；修饰键事件原样放行
                SessionJump.shared.shortcutHints = prefs.sessionCommandKeys
                    && event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
                return event
            }
            switch PanelKey.action(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                   pageKeys: prefs.pageNumberKeys, sessionKeys: prefs.sessionCommandKeys) {
            case .settings:
                self.state.openSettings?()
            case .page(let index):
                // 超出页签数的键也吞掉：放过去的话面板里没有接键盘的控件，系统会「嘟」一声
                let pages = LaunchOptions.Page.visible(shelf: prefs.shelfEnabled)
                if pages.indices.contains(index) { self.state.select(pages[index]) }
            case .session(let index):
                self.jumpToSession(at: index)
            case nil:
                return event
            }
            return nil
        }
    }

    /// ⌘1–⌘5：跳到会话列表第 N 行的终端，和点那一行一样：面板照旧开着、鼠标移出才收（终端被叫到前台，键盘跟着过去）。
    /// 跳不成就切到 AI 页，那一行红字说为什么——从别的页按的话，不切过去看不到原因。
    private func jumpToSession(at index: Int) {
        // 按分组后的显示顺序数，和行尾的 ⌘N 编号一致
        let sessions = SessionRecord.displayOrder(SessionStore.shared.sessions, now: Date())
        guard sessions.indices.contains(index) else { return }
        let session = sessions[index]
        Task { [weak self] in
            if !(await SessionJump.shared.run(session)) { self?.state.select(.ai) }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func turnPage(_ direction: SwipeTracker.Direction) {
        guard let page = SwipeTracker.page(after: state.page, direction: direction,
                                           in: LaunchOptions.Page.visible(shelf: PreferencesStore.shared.prefs.shelfEnabled)) else { return }
        state.select(page)
    }

    // MARK: 右键菜单

    private func showMenu(at point: NSPoint) {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let refresh = NSMenuItem(title: "刷新用量", action: #selector(refreshUsage), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Tally", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: point, in: hostView)
    }

    @objc private func openSettingsWindow() {
        state.openSettings?()
    }

    @objc private func refreshUsage() {
        UsageStore.shared.refresh(reason: .manual)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// 面板展开时的按键判定，纯函数。按物理键位（keyCode）判不看字符：输入法和键盘布局会改字符，
/// 数字行在别的布局下未必打出数字，但键还是那几个键。
enum PanelKey {
    enum Action: Equatable {
        case settings
        /// 第 N 个页签，从 0 数。
        case page(Int)
        /// 会话列表第 N 行，从 0 数。
        case session(Int)
    }

    /// 主键盘数字行 1…9（`kVK_ANSI_1`…`kVK_ANSI_9`，键码不连号）。
    static let digitKeyCodes: [UInt16] = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9].map { UInt16($0) }
    /// ⌘ 跳会话只认 ⌘1–⌘5。
    static let sessionKeyCount = 5

    /// 修饰键只看 ⌘ ⌥ ⌃ ⇧：大写锁、小键盘、fn 不算按了修饰键。
    static func action(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, pageKeys: Bool, sessionKeys: Bool) -> Action? {
        let mods = modifiers.intersection([.command, .option, .control, .shift])
        if keyCode == UInt16(kVK_ANSI_Comma), mods == .command { return .settings }
        guard let index = digitKeyCodes.firstIndex(of: keyCode) else { return nil }
        if mods.isEmpty, pageKeys { return .page(index) }
        if mods == .command, sessionKeys, index < sessionKeyCount { return .session(index) }
        return nil
    }
}

/// 面板缩小后光标算不算还在面板上：在当前 frame 里当然算（宽限结束）；不在但还在缩小前的老区域里也算（宽限继续）；
/// 老区域也不在了才是真离开。纯函数，切矮页时面板从脚下缩走不该把人赶出去。
enum HoverGrace {
    /// 用 AppKit 的 `NSMouseInRect`（非翻转坐标：顶边算里面、底边算外面），和追踪区同一套规则；不用 `CGRect.contains`，
    /// 它不含顶边——面板顶边就是屏幕顶边，光标甩到刘海上会被卡在最顶那一行，追踪区说进来了、轮询却说在外面，开了又收。
    static func judge(mouse: CGPoint, frame: CGRect, shrunkFrom: CGRect?) -> (inside: Bool, keepGrace: Bool) {
        if NSMouseInRect(mouse, frame, false) { return (true, false) }
        if let shrunkFrom, NSMouseInRect(mouse, shrunkFrom, false) { return (true, true) }
        return (false, false)
    }
}

/// 两指横滑的累计判定：累计位移一跨过 40pt 且横向明显大于纵向就翻一页，一次手势只触发一次；纵向为主的是在滚列表，不算。
/// 跨过就触发而不是等手指离开（Atoll 的做法）：快速轻扫的位移大半在 momentum 事件里，而 momentum 没有 phase、被当滚轮忽略，
/// 等 `.ended` 再算的话触摸阶段常常够不着阈值。方向跟自然滚动：手指往左划（内容往左走，Δx 为负）到下一页。
struct SwipeTracker {
    enum Direction { case next, previous }

    static let threshold: CGFloat = 40

    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var active = false
    private var fired = false

    mutating func feed(phase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat) -> Direction? {
        if phase.contains(.began) {
            dx = 0
            dy = 0
            active = true
            fired = false
            return nil
        }
        if phase.contains(.changed) {
            guard active, !fired else { return nil }
            dx += deltaX
            dy += deltaY
            return fireIfCrossed()
        }
        if phase.contains(.cancelled) {
            active = false
            return nil
        }
        if phase.contains(.ended) {
            guard active else { return nil }
            active = false
            return fired ? nil : fireIfCrossed()
        }
        return nil
    }

    private mutating func fireIfCrossed() -> Direction? {
        guard abs(dx) >= Self.threshold, abs(dx) > abs(dy) else { return nil }
        fired = true
        return dx < 0 ? .next : .previous
    }

    /// 三指轻扫事件：AppKit 给 -1 / 0 / 1，负的是往左。
    static func direction(fromSwipeDeltaX deltaX: CGFloat) -> Direction? {
        if deltaX < 0 { return .next }
        if deltaX > 0 { return .previous }
        return nil
    }

    /// 到头不循环。
    static func page(after current: LaunchOptions.Page, direction: Direction, in pages: [LaunchOptions.Page]) -> LaunchOptions.Page? {
        guard let index = pages.firstIndex(of: current) else { return nil }
        let target = direction == .next ? index + 1 : index - 1
        return pages.indices.contains(target) ? pages[target] : nil
    }
}

/// 承载 SwiftUI 内容的视图，顺便把鼠标进出、左右键交给控制器。
///
/// 用 `NSTrackingArea` 而不是 SwiftUI 的 `onHover`：面板不抢激活，
/// SwiftUI 的悬停在非激活窗口里不可靠，AppKit 的 `activeAlways` 才稳。
final class NotchHostView: NSHostingView<NotchView> {

    /// 面板不抢激活，提示态更不会 makeKey。AppKit 对非 key 窗口的首次左键点击的规矩是
    /// 「拿它把窗口变 key，然后丢弃」，除非命中视图这里返回真——不返回的话 `mouseDown` 压根不被调用，
    /// 提示条点了永远没反应（实测：不覆盖 mouseDown=0，覆盖后 mouseDown=1）。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    /// 参数是窗口坐标（原点在左下）。
    var onLeftClick: ((NSPoint) -> Void)?
    var onRightClick: ((NSPoint) -> Void)?
    var isPanelOpen: (() -> Bool)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// SwiftUI 的 `.onHover` 也往这个视图里装追踪区，它们的进出事件同样送到这里：
    /// 光标从一颗按钮上挪开就是一次 mouseExited，不过滤的话面板会当成「离开刘海」收起，再进再开，一直闪。
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === trackingArea { onMouseEntered?() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === trackingArea { onMouseExited?() }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onLeftClick?(event.locationInWindow)
    }

    /// 闭合态右键刘海出 Tally 自己的菜单；展开态把右键交给 SwiftUI，页面里的右键菜单（应用页的「退出」）才弹得出来。
    override func rightMouseDown(with event: NSEvent) {
        if isPanelOpen?() == true {
            super.rightMouseDown(with: event)
        } else {
            onRightClick?(convert(event.locationInWindow, from: nil))
        }
    }
}
