import Foundation
import IOKit.pwr_mgt
import Observation

/// 保持唤醒：一个 IOKit 电源断言。`keepDisplay` 真是 `PreventUserIdleDisplaySleep`（屏幕常亮，系统自然也不睡，等于 `caffeinate -d`），
/// 假是 `PreventUserIdleSystemSleep`（只挡系统闲置休眠，屏幕照常黑，等于 `caffeinate -i`）。
/// 不用 `NoDisplaySleep`：那个名字 10.7 起就标了废弃（`pmset` 里两者登记的都是 `PreventUserIdleDisplaySleep`，效果一样，没理由留旧名）。
///
/// 断言归 Tally 进程所有，进程退出系统自动释放——所以状态要落盘：装新版本、重启 app 之后 `restore()` 把它接回来，
/// 否则「点了杯子然后屏幕还是黑了」，人不知道是升级把它掐了。
@MainActor
@Observable
final class KeepAwake {

    static let shared = KeepAwake()

    /// 可选时长（分钟）；nil 是「一直」。另有一档自定义，值在 `Preferences.keepAwakeCustomMinutes`。
    static let durations: [Int] = [15, 30, 60, 120, 240]

    /// 自定义档：15 分钟一步，15 分钟到 24 小时。面板不抢激活，指望不上输入框，所以是步进。
    static let customStep = 15
    static let customDefault = 90

    /// 步进落到合法值上：先对齐到 15 分钟，再夹进范围。
    static func clampCustom(_ minutes: Int) -> Int {
        min(max(minutes / customStep * customStep, customStep), 24 * 60)
    }

    /// 档位文案，标题行右键菜单与系统页卡片共用。自定义档可能带零头，所以要能写出「1 小时 30 分」。
    static func durationLabel(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(minutes) 分钟" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    private(set) var isActive = false
    /// 到期时刻；开着且不限时为 nil。
    private(set) var until: Date?
    /// 当前选的时长档（分钟）；不限时或没开着是 nil。右键菜单靠它决定勾打在哪一档——
    /// `until` 反推不出来，选 1 小时过了 10 分钟就只剩 50 分钟，跟哪个档都对不上。
    private(set) var minutes: Int?
    /// 当前断言是不是连屏幕一起保持的。
    private(set) var keepsDisplay = false

    private var assertion: IOPMAssertionID = 0
    private var timer: Timer?

    /// minutes 为 nil 就一直保持。
    func start(minutes: Int?, keepDisplay: Bool) {
        start(until: minutes.map { Date().addingTimeInterval(TimeInterval($0) * 60) }, keepDisplay: keepDisplay, minutes: minutes)
    }

    /// deadline 为 nil 就一直保持；重复调用先释放旧断言再建新的，时长和类型按最后一次算。
    func start(until deadline: Date?, keepDisplay: Bool, minutes preset: Int? = nil) {
        stop(persist: false)
        keepsDisplay = keepDisplay
        // 演示模式只翻界面状态、不建断言：录屏时点一下杯子不该让这台机器真的不睡
        if !DemoMode.isOn {
            let result = IOPMAssertionCreateWithName(
                (keepDisplay ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                // ASCII 名字：中文名在 pmset 里显示成空串，`pmset -g assertions | grep -i tally` 就查不到自己那条
                "Tally keep awake" as CFString,
                &assertion
            )
            guard result == kIOReturnSuccess else {
                Log.error("电源断言创建失败: \(result)")
                persist()
                return
            }
        }
        isActive = true
        until = deadline
        minutes = preset
        if let deadline {
            timer = Timer.scheduledTimer(withTimeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
        }
        persist()
    }

    /// 开着的时候切换屏幕常亮：换一种断言，时长不变。
    func setKeepsDisplay(_ keep: Bool) {
        guard isActive, keep != keepsDisplay else { return }
        start(until: until, keepDisplay: keep, minutes: minutes)
    }

    /// 启动时把上次的状态接回来：断言随进程死，落盘的状态才能跨重装。到期的直接清掉。
    func restore(now: Date = Date()) {
        let prefs = PreferencesStore.shared.prefs
        guard prefs.keepAwakeButton, prefs.keepAwakeActive else { return }
        let deadline = prefs.keepAwakeUntil.map { Date(timeIntervalSince1970: $0) }
        guard deadline == nil || deadline! > now else {
            persistCleared()
            return
        }
        start(until: deadline, keepDisplay: prefs.keepAwakeDisplay, minutes: prefs.keepAwakeMinutes)
    }

    private func persist() {
        var prefs = PreferencesStore.shared.prefs
        prefs.keepAwakeActive = isActive
        prefs.keepAwakeUntil = until?.timeIntervalSince1970
        prefs.keepAwakeMinutes = minutes
        PreferencesStore.shared.prefs = prefs
    }

    private func persistCleared() {
        var prefs = PreferencesStore.shared.prefs
        guard prefs.keepAwakeActive || prefs.keepAwakeUntil != nil || prefs.keepAwakeMinutes != nil else { return }
        prefs.keepAwakeActive = false
        prefs.keepAwakeUntil = nil
        prefs.keepAwakeMinutes = nil
        PreferencesStore.shared.prefs = prefs
    }

    func stop() {
        // 合盖不休眠是这个功能的附加项，不能自己留着：断言没了机器闲置照睡，
        // 只剩一个系统级的「合盖不睡」开着，谁也想不起来去关它。
        // 只挂在这条真·关闭路径上，不挂进 stop(persist:)——换档位走的是 start → stop(persist: false)，
        // 挂那儿的话每换一次档合盖开关就被悄悄关掉
        LidSleepBlocker.shared.disable()
        stop(persist: true)
    }

    private func stop(persist shouldPersist: Bool) {
        timer?.invalidate()
        timer = nil
        if isActive, !DemoMode.isOn {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        isActive = false
        until = nil
        minutes = nil
        keepsDisplay = false
        if shouldPersist { persistCleared() }
    }
}
