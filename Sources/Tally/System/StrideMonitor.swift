import AppKit

/// 菜单栏小恐龙：跟着 CPU 睡觉 / 跑步 / 冲刺 / 生气，内存吃紧也冲刺、生气；右边一颗窝里的花斑蛋按内存已用填满（`StrideEgg`）。
/// 恐龙素材是 Stride 定稿的逐帧图（深浅两套）。开关在设置「面板」；关着不建状态栏图标、不起任何定时器。判定规则在 `StrideRule`。
@MainActor
final class StrideMonitor: NSObject {

    static let shared = StrideMonitor()

    /// 点恐龙：控制器接去展开面板到「系统」页；带上按钮在屏幕上的位置，面板拿它算光标的宽限区。
    var onClick: ((CGRect) -> Void)?

    private var item: NSStatusItem?
    private var sampler = SystemSampler()
    private var sampleTimer: Timer?
    private var frameTimer: Timer?
    private var showsValue = false
    private var mood = StrideMood.sleep
    /// 等这一圈播完再换的状态。
    private var pendingMood: StrideMood?
    private var frame = 0
    private var cpu: Double?
    private var memory: Double?
    /// 恐龙帧原图，键「dark/run-03」。
    private var frames: [String: CGImage] = [:]
    /// 帧图拼上蛋的成品，键同上。蛋的样子（深浅、内存整数百分比、颜色档）变了才整份作废，换帧只换这里的图、不现画。
    private var composed: [String: NSImage] = [:]
    private var composedKey = ""
    private var appearanceObservation: NSKeyValueObservation?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// 屏幕睡了、切走了用户会话：停表，没人看的动画不画。
    private var paused = false

    /// 幂等：设置每次变化都调。
    func apply(enabled: Bool, showsValue: Bool) {
        self.showsValue = showsValue
        guard enabled else { return stop() }
        start()
        updateLabel()
    }

    private func start() {
        guard item == nil else { return }
        loadFrames()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeft
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            button.target = self
            button.action = #selector(clicked)
            // 彩色帧不能用模板图，系统不会替我们反色：菜单栏深浅变了自己换那一套
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.showFrame() }
            }
        }
        self.item = item
        let center = NSWorkspace.shared.notificationCenter
        let pausing: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.sessionDidResignActiveNotification, true),
            (NSWorkspace.screensDidWakeNotification, false), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        workspaceObservers = pausing.map { name, pause in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.setPaused(pause) }
            }
        }
        // 采样和换帧分开：采样固定 2 秒，帧率跟着状态走。挂 .common，拖东西、开菜单时也照走
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
        sample()
        scheduleFrames()
        showFrame()
        updateLabel()
    }

    private func stop() {
        guard let item else { return }
        sampleTimer?.invalidate()
        sampleTimer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        appearanceObservation = nil
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        NSStatusBar.system.removeStatusItem(item)
        self.item = nil
        frames = [:]
        composed = [:]
        composedKey = ""
        sampler = SystemSampler()
        mood = .sleep
        pendingMood = nil
        frame = 0
        cpu = nil
        memory = nil
        paused = false
    }

    private func sample() {
        let load = sampler.sampleLoad()
        let memoryReading = load.memory.flatMap { $0.total > 0 ? Double($0.used) / Double($0.total) : nil }
        guard let cpuReading = load.cpu, let memoryReading else {
            // CPU 第一次采样没有上一次可比，下一轮就有。之前有过读数却读不到了是采样坏了：数字换「—」、蛋拿掉、恐龙睡下，
            // 并留一笔——别让旧读数和冲刺的样子一直挂着，空蛋又像「内存很闲」，没有蛋才是「不知道」
            if cpu != nil || memory != nil {
                Log.error("小恐龙采样失败：\(load.cpu == nil ? "CPU" : "内存") 读不到")
                cpu = nil
                memory = nil
                switchMood(to: .sleep)
                updateLabel()
            }
            return
        }
        cpu = cpuReading
        memory = memoryReading
        let next = StrideRule.resolve(cpu: cpuReading, memory: memoryReading, pressure: load.pressure, previous: pendingMood ?? mood)
        if next == mood {
            pendingMood = nil
        } else if StrideRule.switchesNow(to: next, atLoopEnd: false) {
            switchMood(to: next)
        } else {
            pendingMood = next
        }
        scheduleFrames()
        // 蛋跟着内存变；样子没变时成品在缓存里，只是把同一张图再设一次
        showFrame()
        updateLabel()
    }

    private func switchMood(to next: StrideMood) {
        mood = next
        pendingMood = nil
        frame = 0
        scheduleFrames()
        showFrame()
    }

    private func tick() {
        frame += 1
        if frame >= mood.frameCount {
            frame = 0
            if let pending = pendingMood {
                mood = pending
                pendingMood = nil
                scheduleFrames()
            }
        }
        showFrame()
    }

    /// 帧率没变就不动定时器，免得每 2 秒重排一次、动画一顿一顿。
    private func scheduleFrames() {
        guard item != nil, !paused else {
            frameTimer?.invalidate()
            frameTimer = nil
            return
        }
        let interval = 1 / StrideRule.framesPerSecond(mood: mood, cpu: cpu ?? 0)
        if let frameTimer, abs(frameTimer.timeInterval - interval) < 0.001 { return }
        frameTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func setPaused(_ pause: Bool) {
        guard item != nil, pause != paused else { return }
        paused = pause
        sampleTimer?.fireDate = pause ? .distantFuture : Date()
        scheduleFrames()
    }

    private func showFrame() {
        guard let button = item?.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = memory.map { "\(dark)-\(Int(($0 * 100).rounded()))-\(StrideRule.eggTone(memory: $0))" } ?? "\(dark)-无蛋"
        if key != composedKey {
            composed = [:]
            composedKey = key
        }
        let name = "\(dark ? "dark" : "light")/\(mood.frameName(frame))"
        if composed[name] == nil, let source = frames[name] {
            var image = memory.flatMap { StrideEgg.compose(frame: source, memory: $0, dark: dark) }
            if image == nil {
                // 没有内存读数就不画蛋；有读数却拼不出来（位图建不出来）留一笔。两种都缓存不带蛋的帧，不然每一帧都重试一遍
                if memory != nil { Log.error("小恐龙拼蛋失败：\(name)，先只显示恐龙") }
                image = NSImage(cgImage: source, size: NSSize(width: 34, height: 18))
            }
            composed[name] = image
        }
        button.image = composed[name]
    }

    private func updateLabel() {
        guard let button = item?.button else { return }
        let memoryText = memory.map(StrideRule.label) ?? "—"
        let cpuText = cpu.map(StrideRule.label) ?? "—"
        button.title = showsValue ? " \(memoryText)" : ""
        button.toolTip = "CPU \(cpuText) · 内存 \(memoryText)"
        button.setAccessibilityLabel("小恐龙：CPU \(cpuText)，内存 \(memoryText)")
    }

    /// 68 × 36px 的 @2x 帧，按 34 × 18pt 显示；深浅两套共 72 张、不到 300 KB，开着就常驻。
    private func loadFrames() {
        guard frames.isEmpty else { return }
        var missing: [String] = []
        for appearance in ["dark", "light"] {
            for mood in StrideMood.allCases {
                for index in 0..<mood.frameCount {
                    let name = "\(appearance)/\(mood.frameName(index))"
                    guard let url = Bundle.main.url(forResource: mood.frameName(index), withExtension: "png", subdirectory: "stride/\(appearance)"),
                          let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    else {
                        missing.append(name)
                        continue
                    }
                    frames[name] = image
                }
            }
        }
        if !missing.isEmpty {
            Log.error("小恐龙帧图缺 \(missing.count) 张（\(missing.prefix(4).joined(separator: "、"))\(missing.count > 4 ? " 等" : "")），缺的那几帧会是空白")
        }
    }

    @objc private func clicked() {
        onClick?(item?.button?.window?.frame ?? .zero)
    }
}
