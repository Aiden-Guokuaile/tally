import XCTest
@testable import Tally

final class BatteryRuleTests: XCTestCase {

    private func reading(_ percent: Int, _ state: BatteryHealth.State) -> BatteryHealth {
        BatteryHealth(percent: percent, state: state, healthPercent: nil, cycleCount: nil, externalConnected: state != .discharging)
    }

    func testFirstReadingIsSilent() {
        var warned: Set<Int> = []
        XCTAssertNil(BatteryRule.event(previous: nil, current: reading(50, .discharging), warned: &warned))
    }

    func testPlugAndUnplug() {
        var warned: Set<Int> = [20]
        XCTAssertEqual(BatteryRule.event(previous: reading(50, .discharging), current: reading(50, .charging), warned: &warned), .pluggedIn(percent: 50))
        XCTAssertTrue(warned.isEmpty, "接上电源清掉已报过的阈值")
        XCTAssertEqual(BatteryRule.event(previous: reading(80, .charging), current: reading(80, .discharging), warned: &warned), .unplugged(percent: 80))
    }

    func testLowThresholdsFireOncePerDischarge() {
        var warned: Set<Int> = []
        XCTAssertNil(BatteryRule.event(previous: reading(22, .discharging), current: reading(21, .discharging), warned: &warned))
        XCTAssertEqual(BatteryRule.event(previous: reading(21, .discharging), current: reading(19, .discharging), warned: &warned), .low(percent: 19, threshold: 20))
        XCTAssertNil(BatteryRule.event(previous: reading(19, .discharging), current: reading(15, .discharging), warned: &warned), "20 报过了，10 还没到")
        XCTAssertEqual(BatteryRule.event(previous: reading(15, .discharging), current: reading(9, .discharging), warned: &warned), .low(percent: 9, threshold: 10))
        XCTAssertNil(BatteryRule.event(previous: reading(9, .discharging), current: reading(8, .discharging), warned: &warned))
        // 一下子从 50 掉到 5：两个阈值一起算报过，只弹一次，按最低的
        var fresh: Set<Int> = []
        XCTAssertEqual(BatteryRule.event(previous: reading(50, .discharging), current: reading(5, .discharging), warned: &fresh), .low(percent: 5, threshold: 10))
        XCTAssertEqual(fresh, [20, 10])
    }

    func testFullOnlyAfterCharging() {
        var warned: Set<Int> = []
        XCTAssertEqual(BatteryRule.event(previous: reading(99, .charging), current: reading(100, .full), warned: &warned), .full)
        XCTAssertNil(BatteryRule.event(previous: reading(100, .full), current: reading(100, .full), warned: &warned))
    }

    func testUnplugWhileOnPowerButNotCharging() {
        // 优化充电停在 80%：接着电源但 state 不是充电，拔掉也要报
        var warned: Set<Int> = []
        XCTAssertEqual(BatteryRule.event(previous: reading(80, .onPower), current: reading(80, .discharging), warned: &warned), .unplugged(percent: 80))
        XCTAssertEqual(BatteryRule.event(previous: reading(80, .discharging), current: reading(80, .onPower), warned: &warned), .pluggedIn(percent: 80))
        XCTAssertNil(BatteryRule.event(previous: reading(80, .onPower), current: reading(80, .charging), warned: &warned), "接着电源开始充不算事件")
    }
}

final class PeekTests: XCTestCase {

    func testBatteryEventsMapToStyles() {
        XCTAssertEqual(Peek.battery(.pluggedIn(percent: 80)).style, .pluggedIn)
        XCTAssertEqual(Peek.battery(.unplugged(percent: 80)).style, .unplugged)
        XCTAssertEqual(Peek.battery(.low(percent: 19, threshold: 20)).style, .low)
        XCTAssertEqual(Peek.battery(.low(percent: 9, threshold: 10)).tint, .red, "10% 以下红")
        XCTAssertEqual(Peek.battery(.full).style, .full)
        XCTAssertNotEqual(Peek.battery(.full, now: Date(timeIntervalSince1970: 1)).id, Peek.battery(.full, now: Date(timeIntervalSince1970: 2)).id, "每条 id 不同才会重放入场动画")
    }

    func testSessionPeekUsesTitleAndFirstLineOfMessage() {
        let record = SessionRecord(sessionId: "s", state: .done, cwd: "/tmp/x", title: "标题", transcriptPath: "", message: "第一行\n第二行", updatedAt: 1)
        let peek = Peek.session(record)
        XCTAssertEqual(peek.style, .session)
        XCTAssertEqual(peek.title, "标题")
        XCTAssertEqual(peek.subtitle, "第一行 第二行")
        XCTAssertEqual(peek.sessionId, "s", "点一下能跳回去")
        XCTAssertEqual(peek.duration(session: 5, battery: 4), 5)
        XCTAssertEqual(Peek.session(SessionRecord(sessionId: "s", state: .done, cwd: "/tmp/x", title: nil, transcriptPath: "", message: "", updatedAt: 1)).subtitle, "跑完了 · 点这里跳过去")
    }

    func testWaitingSessionsPeekAsAsk() {
        let ask = Peek.session(SessionRecord(sessionId: "s", state: .waitingPermission, cwd: "/tmp/x", title: "标题", transcriptPath: "", message: nil, updatedAt: 1))
        XCTAssertEqual(ask.style, .ask)
        XCTAssertEqual(ask.label, "等审批")
        XCTAssertEqual(ask.duration(session: 5, battery: 4), 8, "等审批停得最久")
        XCTAssertEqual(Peek.session(SessionRecord(sessionId: "s", state: .waitingInput, cwd: "/tmp/x", title: "标题", transcriptPath: "", message: nil, updatedAt: 1)).label, "等输入")
        XCTAssertGreaterThan(ask.estimatedContentWidth, 100)
    }

    /// 停留时长跟着设置走：等审批固定比跑完多 askExtra，电池走自己那个。
    func testPeekDurationFollowsPreferences() {
        let done = Peek.session(SessionRecord(sessionId: "s", state: .done, cwd: "/tmp/x", title: "标题", transcriptPath: "", message: "", updatedAt: 1))
        let ask = Peek.session(SessionRecord(sessionId: "s", state: .waitingPermission, cwd: "/tmp/x", title: "标题", transcriptPath: "", message: nil, updatedAt: 1))
        XCTAssertEqual(done.duration(session: 9, battery: 4), 9)
        XCTAssertEqual(ask.duration(session: 9, battery: 4), 9 + Peek.askExtra, "等审批比跑完多留，真要人来的那种")
        XCTAssertEqual(Peek.battery(.full).duration(session: 9, battery: 6), 6, "电池走自己那个秒数")
    }

    func testQuotaPeeks() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let high = Peek.quota(QuotaEvent(provider: .claude, window: "5 小时", kind: .high(percent: 82), resetsAt: nil), now: now)
        XCTAssertEqual(high.style, .quotaHigh)
        XCTAssertEqual(high.tint, .orange)
        XCTAssertEqual(high.label, "配额 82%")
        XCTAssertEqual(high.title, "Claude · 5 小时")
        XCTAssertEqual(high.subtitle, "已用 82%")
        XCTAssertNil(high.sessionId, "不可点")
        XCTAssertEqual(high.duration(session: 7, battery: 3), 7, "停留跟会话提示走")
        let exhausted = Peek.quota(QuotaEvent(provider: .codex, window: "7 天", kind: .exhausted, resetsAt: now.addingTimeInterval(3600)), now: now)
        XCTAssertEqual(exhausted.tint, .red)
        XCTAssertTrue(exhausted.subtitle?.hasPrefix("用完了 · ") == true, "带重置时刻")
        XCTAssertEqual(Peek.quota(QuotaEvent(provider: .codex, window: "7 天", kind: .reset, resetsAt: nil), now: now).style, .quotaReset)
    }

    /// 这条钉的是那个 bug 的一半：会话提示条挂着时不许悬停展开，
    /// 否则 open() 的 clearPeek() 抢在人按下鼠标之前把它清掉，点击落到空处。
    func testSessionPeekBlocksHoverOpen() {
        let session = Peek.session(SessionRecord(sessionId: "s", state: .done, cwd: "/tmp/x", title: "标题", transcriptPath: "", message: "", updatedAt: 1))
        XCTAssertTrue(Peek.holdsHoverOpen(session), "会话类要拦住悬停展开")
        XCTAssertFalse(Peek.holdsHoverOpen(Peek.battery(.full)), "电池类不拦，拦了悬停展开要被堵住一整条提示条的时间")
        XCTAssertFalse(Peek.holdsHoverOpen(nil))
    }

    /// 低优先级的不顶掉正挂着的高优先级：电池提示不许盖掉「等输入」；同一个会话的新状态直接换。
    func testPeekPriorityQueue() {
        func session(_ id: String, _ state: SessionRecord.State) -> Peek {
            Peek.session(SessionRecord(sessionId: id, state: state, cwd: "/tmp/x", title: "标题", transcriptPath: "", message: nil, updatedAt: 1))
        }
        let ask = session("a", .waitingInput)
        let done = session("b", .done)
        let battery = Peek.battery(.full)
        let quota = Peek.quota(QuotaEvent(provider: .claude, window: "5 小时", kind: .exhausted, resetsAt: nil))
        XCTAssertEqual(PeekQueue.decide(incoming: battery, showing: nil), .show)
        XCTAssertEqual(PeekQueue.decide(incoming: battery, showing: ask), .wait, "电池提示不许盖掉等输入")
        XCTAssertEqual(PeekQueue.decide(incoming: quota, showing: done), .wait)
        XCTAssertEqual(PeekQueue.decide(incoming: Peek.shelf(names: ["a"], enabled: true), showing: quota), .wait, "一样高排队，不顶掉")
        XCTAssertEqual(PeekQueue.decide(incoming: session("c", .waitingPermission), showing: ask), .wait,
                       "两个会话前后脚都在等审批：后来的排队，先来的不能被顶掉")
        XCTAssertEqual(PeekQueue.decide(incoming: ask, showing: done), .show, "等你的顶掉跑完的")
        XCTAssertEqual(PeekQueue.decide(incoming: session("a", .done), showing: ask), .show, "同一个会话的新状态直接换，不留过时的等输入")
        XCTAssertEqual(PeekQueue.keep(battery, over: quota), quota, "队里留高的")
        XCTAssertEqual(PeekQueue.keep(quota, over: battery), quota)
        XCTAssertEqual(PeekQueue.keep(battery, over: nil), battery)
    }

    func testAlertSoundCoalescesBursts() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(AlertSound.shouldPlay(lastPlayed: nil, now: now))
        XCTAssertFalse(AlertSound.shouldPlay(lastPlayed: now.addingTimeInterval(-1), now: now), "几个会话前后脚跑完只响一声")
        XCTAssertTrue(AlertSound.shouldPlay(lastPlayed: now.addingTimeInterval(-AlertSound.quietWindow), now: now))
    }

    func testOnlyBatteryPeeksStayOutOfSystemNotifications() {
        let done = Peek.session(SessionRecord(sessionId: "s", state: .done, cwd: "/tmp/x", title: "标题", transcriptPath: "", message: "", updatedAt: 1))
        XCTAssertTrue(done.notifiesWithoutNotch)
        XCTAssertTrue(Peek.quota(QuotaEvent(provider: .codex, window: "7 天", kind: .exhausted, resetsAt: nil)).notifiesWithoutNotch)
        XCTAssertTrue(Peek.shelf(names: ["a"], enabled: true).notifiesWithoutNotch)
        XCTAssertFalse(Peek.battery(.full).notifiesWithoutNotch, "电池的不发，系统自己会说")
    }

    func testShelfPeek() {
        let one = Peek.shelf(names: ["a.png"], enabled: true)
        XCTAssertEqual(one.style, .shelf)
        XCTAssertEqual(one.title, "a.png")
        XCTAssertNil(one.sessionId, "不可点")
        XCTAssertEqual(one.duration(session: 9, battery: 3), 3, "停留跟电池走")
        XCTAssertEqual(Peek.shelf(names: ["a", "b"], enabled: true).title, "2 个文件")
        XCTAssertEqual(Peek.shelf(names: ["a"], enabled: false).label, "文件架没开")
    }

    /// 点提示条按设置三选一；电池类不可点，给空计划。
    func testPeekTapPlan() {
        let session = Peek.session(SessionRecord(sessionId: "s", state: .done, cwd: "/tmp/x", title: "标题", transcriptPath: "", message: "", updatedAt: 1))
        XCTAssertEqual(session.tapPlan(.terminal), Peek.TapPlan(focusTerminal: true, openAI: false))
        XCTAssertEqual(session.tapPlan(.ai), Peek.TapPlan(focusTerminal: false, openAI: true))
        XCTAssertEqual(session.tapPlan(.both), Peek.TapPlan(focusTerminal: true, openAI: true))
        XCTAssertEqual(Peek.battery(.full).tapPlan(.both), Peek.TapPlan(), "电池提示条点了什么都不做")
        XCTAssertEqual(PeekTapAction.parse("乱写的"), .terminal, "认不出的回落到默认：跳回对应终端")
    }
}

final class KeepAwakeTests: XCTestCase {

    @MainActor
    func testAssertionLifecycle() {
        let keep = KeepAwake()
        keep.start(minutes: 15, keepDisplay: false)
        XCTAssertTrue(keep.isActive)
        XCTAssertNotNil(keep.until)
        XCTAssertFalse(keep.keepsDisplay)
        let until = keep.until
        keep.setKeepsDisplay(true)
        XCTAssertTrue(keep.keepsDisplay, "开着时切屏幕常亮换断言类型")
        XCTAssertEqual(keep.until!.timeIntervalSince1970, until!.timeIntervalSince1970, accuracy: 1, "到期时刻不变")
        keep.start(minutes: nil, keepDisplay: true)
        XCTAssertTrue(keep.isActive)
        XCTAssertNil(keep.until, "不限时没有到期时刻")
        keep.stop()
        XCTAssertFalse(keep.isActive)
        keep.stop()
        XCTAssertFalse(keep.isActive, "重复 stop 无害")
    }

    /// 右键菜单的勾靠 `minutes` 定位，所以选了哪档要记住，且切屏幕常亮时不能丢。
    @MainActor
    func testRemembersSelectedDuration() {
        let keep = KeepAwake()
        keep.start(minutes: 60, keepDisplay: false)
        XCTAssertEqual(keep.minutes, 60)
        keep.setKeepsDisplay(true)
        XCTAssertEqual(keep.minutes, 60, "换断言类型不丢档")
        keep.start(minutes: nil, keepDisplay: false)
        XCTAssertNil(keep.minutes, "一直保持唤醒不属于任何档")
        keep.start(minutes: 15, keepDisplay: false)
        keep.stop()
        XCTAssertNil(keep.minutes, "关掉就没有勾")
    }

    /// 自定义档会带零头，档位文案得写得出「1 小时 30 分」；步进要对齐到 15 分钟并夹在范围里。
    @MainActor
    func testCustomDurationLabelAndClamp() {
        XCTAssertEqual(KeepAwake.durationLabel(15), "15 分钟")
        XCTAssertEqual(KeepAwake.durationLabel(60), "1 小时")
        XCTAssertEqual(KeepAwake.durationLabel(90), "1 小时 30 分")
        XCTAssertEqual(KeepAwake.clampCustom(0), 15, "下限 15 分钟")
        XCTAssertEqual(KeepAwake.clampCustom(-30), 15)
        XCTAssertEqual(KeepAwake.clampCustom(100), 90, "对齐到 15 分钟一步")
        XCTAssertEqual(KeepAwake.clampCustom(9999), 24 * 60, "上限 24 小时")
    }
}

final class LidSleepBlockerTests: XCTestCase {

    /// 免密规则是这个功能的地基（授权层起不了长期进程，实测后台进程当场被杀），
    /// 所以规则文本要盯死：命令必须和实际跑的逐字一致，装之前必须验语法。
    func testSudoersRule() {
        let rule = LidSleepBlocker.sudoersInstallScript(user: "someone")
        XCTAssertTrue(rule.contains("someone ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"),
                      "两条 pmset 要逐字匹配实际调用，否则免密不生效、静默失败")
        XCTAssertTrue(rule.contains("/bin/rm -f /etc/sudoers.d/tally"), "放行删掉自己这条规则，撤销时才不用再输密码")
        XCTAssertTrue(rule.contains("/usr/sbin/visudo -cf"), "验完语法再装：写坏 sudoers 会把整个 sudo 搞挂")
        XCTAssertTrue(rule.contains("install -m 440 -o root -g wheel"))
        XCTAssertTrue(rule.range(of: #"visudo -cf "\$T" >/dev/null 2>&1 \|\| \{ /bin/rm -f "\$T"; exit 1; \}"#, options: .regularExpression) != nil,
                      "验不过要连临时文件一起收掉，不能留半条规则")
    }

    /// `pmset -g` 里开着才有 SleepDisabled 那一行；别把 sleep / displaysleep 那几行读串了。
    func testSleepDisabledParsing() {
        // 样本照 `pmset -g` 的真实输出抄（`od -c` 验过）：分隔符是制表符，不是空格
        let on = " hibernatemode\t\t3\n SleepDisabled\t\t1\n displaysleep\t\t10"
        let off = " sleep\t\t1 (sleep prevented by caffeinate)\n displaysleep\t\t10 (display sleep prevented by Tally)"
        XCTAssertTrue(LidSleepBlocker.sleepDisabled(inPmsetOutput: on))
        XCTAssertFalse(LidSleepBlocker.sleepDisabled(inPmsetOutput: off))
        XCTAssertFalse(LidSleepBlocker.sleepDisabled(inPmsetOutput: " SleepDisabled\t\t0"), "关着是 0，不是没这行")
        XCTAssertTrue(LidSleepBlocker.sleepDisabled(inPmsetOutput: " SleepDisabled        1"), "空格分隔也得认")
    }
}
final class PrivacyWatcherTests: XCTestCase {

    /// 真机：内建麦克风与摄像头都在，挂上监听后设备数各 ≥ 1；关掉后清零。没有设备的机器跳过。
    @MainActor
    func testAttachesToBuiltInDevices() throws {
        guard !PrivacyWatcher.audioInputDevices().isEmpty, !PrivacyWatcher.cameraDevicesList().isEmpty else {
            throw XCTSkip("没有输入设备")
        }
        let watcher = PrivacyWatcher()
        watcher.setEnabled(true)
        XCTAssertGreaterThanOrEqual(watcher.deviceCounts.microphones, 1)
        XCTAssertGreaterThanOrEqual(watcher.deviceCounts.cameras, 1)
        watcher.setEnabled(false)
        XCTAssertEqual(watcher.deviceCounts.microphones, 0)
        XCTAssertEqual(watcher.deviceCounts.cameras, 0)
        XCTAssertFalse(watcher.cameraInUse)
        XCTAssertFalse(watcher.microphoneInUse)
    }
}
