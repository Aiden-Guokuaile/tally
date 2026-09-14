import AppKit
import SwiftUI

/// 系统页：「硬件」「电池」并排，下面保持唤醒、压力条、内存大户、废纸篓。
struct SystemPage: View {
    var store = SystemStore.shared
    var preferences = PreferencesStore.shared

    var body: some View {
        let s = store.sample
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Card("硬件", symbol: "cpu", tint: .blue) {
                    let hw = store.hardware
                    line(hw.map { "\($0.chip) · \($0.performanceCores + ($0.efficiencyCores ?? 0)) 核 · \(ByteFormat.string($0.memoryTotal))" } ?? "—")
                    line(hw.map { "macOS \($0.osVersion) · 已开机 \(HardwareInfo.uptimeText(from: $0.bootTime, now: Date()))" } ?? "—")
                }
                Card("电池", symbol: "battery.100percent", tint: .green) {
                    if let battery = s.battery {
                        // 健康度优先用「系统信息」那个口径，对不上会被当成 bug
                        let health = store.batteryHealthPercent ?? battery.healthPercent
                        (Text("\(battery.percent)% \(battery.state.label)").foregroundStyle(color(s.batteryLevel) ?? .white.opacity(0.85))
                            + Text(" · 最大容量 ").foregroundStyle(.white.opacity(0.55))
                            + Text(health.map { "\($0)%" } ?? "—").foregroundStyle(color(BatteryHealth.level(health)) ?? .white.opacity(0.85))
                            + Text(" · 循环 " + (battery.cycleCount.map { "\($0) 次" } ?? "—")).foregroundStyle(.white.opacity(0.85)))
                            .font(.system(size: 11, design: .rounded).monospacedDigit())
                            .lineLimit(1)
                    } else {
                        line("无电池")
                    }
                    HStack(spacing: 6) {
                        Text("废纸篓 " + trashText)
                            .font(.system(size: 11, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if let message = store.trashMessage {
                            Text(message)
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                                .lineLimit(1)
                        }
                        // 黑底上系统的 bordered 按钮几乎看不见，和网络页「打开 ▸」用同一种胶囊
                        Button {
                            confirmEmptyTrash()
                        } label: {
                            Text(store.emptying ? "清空中…" : "清空")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(trashButtonEnabled ? 0.85 : 0.35))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.white.opacity(trashButtonEnabled ? 0.14 : 0.06)))
                        }
                        .buttonStyle(.plain)
                        .disabled(!trashButtonEnabled)
                    }
                }
            }
            // 跟着标题行那颗杯子的总开关走：关了功能就不起，控件也不该留在这儿
            if preferences.prefs.keepAwakeButton {
                KeepAwakeCard()
            }
            Card("压力", symbol: "gauge.with.dots.needle.67percent", tint: .purple) {
                MetricBar(name: "内存", fraction: fraction(s.memoryUsed, s.memoryTotal), level: s.memoryLevel,
                          text: pair(s.memoryUsed, s.memoryTotal, prefix: "已用 ") + (s.pressure.map { " · \($0.label)" } ?? ""))
                HStack(spacing: 16) {
                    MetricBar(name: "CPU", fraction: s.cpuFraction, level: s.cpuLevel,
                              text: s.cpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—", textWidth: 44)
                    MetricBar(name: "磁盘", fraction: usedFraction(available: s.diskAvailable, total: s.diskTotal), level: s.diskLevel,
                              text: pair(s.diskAvailable, s.diskTotal, prefix: "可用 "), textWidth: 150)
                }
                if let swapUsed = s.swapUsed, swapUsed > 0 {
                    MetricBar(name: "交换", fraction: fraction(s.swapUsed, s.swapTotal), level: nil, text: pair(s.swapUsed, s.swapTotal))
                }
                if !s.topProcesses.isEmpty {
                    Text("内存大户")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 2)
                    ForEach(s.topProcesses, id: \.name) { process in
                        KeyValueRow(key: process.name, value: ByteFormat.string(process.bytes))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
    }

    private var trashButtonEnabled: Bool {
        !store.emptying && (store.trash?.count ?? 0) > 0
    }

    private var trashText: String {
        guard let trash = store.trash else { return "扫描中…" }
        return "\(ByteFormat.string(trash.bytes)) · \(trash.count) 项"
    }

    /// 永久删除前必弹确认。
    private func confirmEmptyTrash() {
        guard let trash = store.trash, trash.count > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "清空废纸篓？"
        alert.informativeText = "将永久删除 \(trash.count) 项（\(ByteFormat.string(trash.bytes))），不能撤销。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        // 不让路的话弹框在面板底下，看不见也点不到（NotchPanel.steppingAside 里写了为什么只能压面板）
        if NotchPanel.steppingAside({ alert.runModal() }) == .alertFirstButtonReturn {
            store.emptyTrash()
        }
    }

    private func color(_ level: SystemSample.Level?) -> Color? {
        switch level {
        case .critical: return .red
        case .warn: return .yellow
        case .ok: return .green
        case nil: return nil
        }
    }

    private func fraction(_ used: UInt64?, _ total: UInt64?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return Double(used) / Double(total)
    }

    private func usedFraction(available: UInt64?, total: UInt64?) -> Double? {
        guard let available, let total, total > 0 else { return nil }
        return 1 - Double(available) / Double(total)
    }

    /// 「21.3 / 48 GB」：两边单位一样时只写一次；采不到就一个「—」。
    private func pair(_ a: UInt64?, _ b: UInt64?, prefix: String = "") -> String {
        guard let a, let b else { return "—" }
        return prefix + SystemPage.pairText(ByteFormat.string(a), ByteFormat.string(b))
    }

    static func pairText(_ left: String, _ right: String) -> String {
        let leftUnit = left.split(separator: " ").last ?? ""
        let rightUnit = right.split(separator: " ").last ?? ""
        guard leftUnit == rightUnit, let number = left.split(separator: " ").first else { return left + " / " + right }
        return number + " / " + right
    }
}

/// 保持唤醒卡片：标题行那颗杯子只有 24 × 22pt，还得先悬停展开刘海再右键，选时长太难点。
/// 这里把六个档位摊成胶囊，当前那档填橙色；杯子留着当快捷开关和状态灯。
private struct KeepAwakeCard: View {
    var keepAwake = KeepAwake.shared
    var lid = LidSleepBlocker.shared
    var preferences = PreferencesStore.shared
    /// 「自定义」那颗点开之后才出现的步进行。
    @State private var editingCustom = false
    /// 授权框弹着的时候不让重复点。
    @State private var authorizing = false

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        Card("保持唤醒", symbol: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", tint: .orange) {
            HStack(spacing: 6) {
                let keepDisplay = preferences.prefs.keepAwakeDisplay
                pill("一直", on: keepAwake.isActive && keepAwake.until == nil) {
                    keepAwake.start(minutes: nil, keepDisplay: keepDisplay)
                }
                ForEach(KeepAwake.durations, id: \.self) { minutes in
                    pill(KeepAwake.durationLabel(minutes), on: keepAwake.minutes == minutes) {
                        keepAwake.start(minutes: minutes, keepDisplay: keepDisplay)
                    }
                }
                // 点它只做一件事：展开步进行去设一个时长。不直接启动，省得人去猜这一下是设还是开
                pill(customLabel, on: custom != nil && keepAwake.minutes == custom) { editingCustom.toggle() }
                Spacer(minLength: 8)
                if keepAwake.isActive {
                    pill("关闭", on: false) { keepAwake.stop() }
                }
            }
            if editingCustom {
                HStack(spacing: 6) {
                    stepper("minus", by: -KeepAwake.customStep)
                    Text(KeepAwake.durationLabel(custom ?? KeepAwake.customDefault))
                        .font(.system(size: 11, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(minWidth: 68)
                    stepper("plus", by: KeepAwake.customStep)
                    pill("开始", on: false) {
                        // 一次没调过就直接开始也要把这档记下来，不然胶囊和右键菜单里都看不见它
                        let minutes = custom ?? KeepAwake.customDefault
                        preferences.prefs.keepAwakeCustomMinutes = minutes
                        editingCustom = false
                        keepAwake.start(minutes: minutes, keepDisplay: preferences.prefs.keepAwakeDisplay)
                    }
                    Spacer(minLength: 8)
                }
            }
            HStack(spacing: 6) {
                Text(status)
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 8)
                pill("合盖也不休眠", on: lid.isActive) { toggleLid() }
                    .disabled(authorizing)
                pill("屏幕也常亮", on: preferences.prefs.keepAwakeDisplay) {
                    let on = !preferences.prefs.keepAwakeDisplay
                    preferences.prefs.keepAwakeDisplay = on
                    keepAwake.setKeepsDisplay(on)
                }
            }
            if lid.isActive {
                Text("合盖后机器继续跑，也不会锁屏（锁屏是跟着休眠触发的）——要锁先按 ⌃⌘Q 再合，不影响 agent。注意散热")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if let failure = lid.failure {
                // 不说的话就是「点了没反应」：别人拿到这个 app，最常见的失败是账号不是管理员
                Text(failure)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            if lid.residue {
                // 上一轮被强杀，系统还留着「合盖不睡」。不说的话机器会一直不休眠，人还找不到是谁干的
                HStack(spacing: 6) {
                    Text("系统仍留着上次的「合盖不休眠」，没能自动恢复")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    pill("恢复", on: false) {
                        authorizing = true
                        Task { _ = await lid.clearResidue(); authorizing = false }
                    }
                    .disabled(authorizing)
                }
            }
        }
    }

    private var custom: Int? { preferences.prefs.keepAwakeCustomMinutes }

    private var customLabel: String { custom.map(KeepAwake.durationLabel) ?? "自定义" }

    /// 开要一次管理员密码，关只是删个标记文件（看门狗几秒内抹回去），所以只有开这一路要转圈。
    private func toggleLid() {
        if lid.isActive {
            lid.disable()
            return
        }
        authorizing = true
        Task {
            _ = await lid.enable()
            authorizing = false
        }
    }

    /// 自定义时长的步进；面板不抢激活，输入框指望不上，所以用加减。
    private func stepper(_ symbol: String, by delta: Int) -> some View {
        Button {
            preferences.prefs.keepAwakeCustomMinutes = KeepAwake.clampCustom((custom ?? KeepAwake.customDefault) + delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 20, height: 18)
                .background(Capsule().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }

    private var status: String {
        guard keepAwake.isActive else { return "关着，Mac 闲置一会儿就会休眠" }
        guard let until = keepAwake.until else { return "一直开着，直到手动关闭" }
        return "到 \(Self.clock.string(from: until)) 自动关闭"
    }

    /// 胶囊按钮，选中填橙色。样式跟废纸篓「清空」、代理卡「打开 ▸」一致。
    private func pill(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(on ? Color.orange : Color.white.opacity(0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.orange.opacity(0.22) : Color.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}
