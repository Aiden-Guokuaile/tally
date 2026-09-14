import AppKit
import SwiftUI

/// 设置窗口各项的表单。开关一律写进 `Preferences` 落盘，控制器收到 `onChange` 起停对应功能。
/// 一个开关一句解释，放在表单节脚注里；一个开关只管一件事。

/// 功能开关的绑定：写进设置就落盘。
@MainActor
func preferenceToggle(_ key: WritableKeyPath<Preferences, Bool>) -> Binding<Bool> {
    Binding(
        get: { PreferencesStore.shared.prefs[keyPath: key] },
        set: { PreferencesStore.shared.prefs[keyPath: key] = $0 }
    )
}

/// 通用：开机自启、快捷键、退出。
struct GeneralSettings: View {
    var preferences = PreferencesStore.shared
    @State private var launchError: String?
    @State private var hotKeyError: String?

    var body: some View {
        Form {
            Section {
                if let saveError = preferences.saveError {
                    Text(saveError).foregroundStyle(.red).font(.caption)
                }
                Toggle("开机自启", isOn: launchAtLogin)
                if let launchError {
                    Text(launchError).foregroundStyle(.red).font(.caption)
                }
            } footer: {
                Text("登录时自动启动 Tally（写一个 LaunchAgent）。")
            }
            Section {
                Toggle("\(HotKeyCenter.label) 展开 / 收起面板", isOn: hotKey)
                if let hotKeyError {
                    Text(hotKeyError).foregroundStyle(.red).font(.caption)
                }
            } footer: {
                Text("全局快捷键，不需要辅助功能授权。选 ⌥⇧ 是因为 ⌃⌥ 打头的组合常被代理类工具占用。")
            }
            Section {
                HStack {
                    Text("Tally \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("退出 Tally") { NSApp.terminate(nil) }
                }
            }
        }
        .onAppear { hotKeyError = Self.hotKeyProblem(enabled: preferences.prefs.hotKeyEnabled) }
    }

    /// 开着却没注册上：别的 app 先占了同一组合键。
    private static func hotKeyProblem(enabled: Bool) -> String? {
        enabled && !HotKeyCenter.shared.isActive ? "\(HotKeyCenter.label) 注册失败，可能被别的 app 占用" : nil
    }

    private var hotKey: Binding<Bool> {
        Binding(
            get: { preferences.prefs.hotKeyEnabled },
            set: { enabled in
                preferences.prefs.hotKeyEnabled = enabled
                HotKeyCenter.shared.setEnabled(enabled)
                hotKeyError = Self.hotKeyProblem(enabled: enabled)
            }
        )
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { preferences.prefs.launchAtLogin },
            set: { enable in
                if let error = LaunchAgent.setEnabled(enable) {
                    launchError = error
                    return
                }
                launchError = nil
                preferences.prefs.launchAtLogin = enable
            }
        )
    }
}

/// 面板：怎么开合、标题行有什么、截屏时藏不藏。
struct PanelSettings: View {
    var keepAwake = KeepAwake.shared
    var lid = LidSleepBlocker.shared

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        Form {
            Section {
                Toggle("鼠标停在刘海上展开", isOn: preferenceToggle(\.hoverToOpen))
            } header: {
                Text("开合")
            } footer: {
                Text("关了就只剩 \(HotKeyCenter.label)。展开后两指横滑或三指轻扫翻页。")
            }
            Section {
                Toggle("数字键 1–9 切到第 N 个页签", isOn: preferenceToggle(\.pageNumberKeys))
                Toggle("⌘1–⌘5 跳到第 N 个会话的终端", isOn: preferenceToggle(\.sessionCommandKeys))
            } header: {
                Text("键盘")
            } footer: {
                Text("只在面板展开时有效：展开时键盘归面板，收起后数字和 ⌘N 照常打进原来的 app。会话按 AI 页列表的顺序数，最上面的是 1；跳过去和点那一行一样，接着打字进的就是那个终端，面板等鼠标移出再收。")
            }
            Section {
                // 这一条才是真开关：原来这一节只有「屏幕也常亮」，它只挑模式不启动，勾了以为开了、屏幕照黑
                Toggle("现在保持唤醒", isOn: Binding(
                    get: { keepAwake.isActive },
                    set: { on in
                        if on {
                            keepAwake.start(minutes: nil, keepDisplay: PreferencesStore.shared.prefs.keepAwakeDisplay)
                        } else {
                            keepAwake.stop()
                        }
                    }
                ))
                if keepAwake.isActive {
                    Text(keepAwake.until.map { "到 \(Self.clock.string(from: $0)) 自动关闭" } ?? "一直开着，直到手动关闭")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("合盖也不休眠", isOn: Binding(
                    get: { lid.isActive },
                    set: { on in
                        if on {
                            Task { _ = await lid.enable() }
                        } else {
                            lid.disable()
                        }
                    }
                ))
                Toggle("合盖不休眠的免密规则", isOn: Binding(
                    get: { lid.passwordless },
                    set: { on in
                        Task { _ = on ? await lid.installPasswordless() : await lid.removePasswordless() }
                    }
                ))
                Toggle("保持唤醒时屏幕也常亮", isOn: Binding(
                    get: { PreferencesStore.shared.prefs.keepAwakeDisplay },
                    set: { on in
                        PreferencesStore.shared.prefs.keepAwakeDisplay = on
                        KeepAwake.shared.setKeepsDisplay(on)
                    }
                ))
                Toggle("标题行「保持唤醒」按钮", isOn: preferenceToggle(\.keepAwakeButton))
            } header: {
                Text("保持唤醒")
            } footer: {
                Text("就是 caffeinate 的按钮版：Mac 几分钟没人碰会休眠，休眠后 agent 任务全停。开着就不休眠（等于 caffeinate -i，勾了「屏幕也常亮」等于 -d）。标题行那颗杯子点一下开 / 关、右键选时长；开着时杯子实心橙色。状态会记住：装新版本、重启 Tally 之后自动接回来。\n\n「合盖也不休眠」是另一回事：电源断言只挡闲置休眠，合盖走的是更低一层的 clamshell 休眠，任何断言都拦不住，所以它动的是系统级的开关，开一次要管理员密码。合盖后机器继续跑，注意散热；关掉、到期、退出 Tally 都会自动恢复，不用再输密码。自定义时长在系统页那张卡片上设。\n\n「合盖也不休眠」要一条免密规则：第一次开的时候往 /etc/sudoers.d/tally 装一条，只放行 pmset 那两条命令和「删掉这条规则自己」，输一次密码，以后跨重启、跨重装都不再问。取消这里的勾选就把规则删掉（不用再输密码），合盖不休眠也跟着关掉。\n\n开着的时候合盖，机器继续跑、屏幕也不会锁——锁屏是跟着休眠触发的，不睡就没有锁的时机。要带着走先按 ⌃⌘Q 锁一下再合盖，锁屏不影响 agent 继续跑。")
            }
            Section {
                Toggle("截屏和共享屏幕时隐藏面板", isOn: preferenceToggle(\.hideFromCapture))
            } header: {
                Text("隐私")
            } footer: {
                Text("窗口服务器层面不给别的进程读这个窗口，截图和共享屏幕里都看不到面板。")
            }
        }
    }
}

/// 提示：闭合态什么时候垂提示条、点了做什么；标题行画不画占用点。
struct AlertSettings: View {
    var body: some View {
        Form {
            Section {
                Toggle("接电 / 拔电 / 低电 / 充满时提示", isOn: preferenceToggle(\.batteryPeek))
                peekSeconds("电池提示停留", \.peekBatterySeconds)
            } footer: {
                Text("面板闭合时从刘海往下垂一条。低电在 20% 和 10% 各提示一次。事件驱动，不轮询。电池提示不可点，点它不会有任何动作。")
            }
            Section {
                Picker("点提示条时", selection: Binding(
                    get: { PeekTapAction.parse(PreferencesStore.shared.prefs.peekTapAction) },
                    set: { PreferencesStore.shared.prefs.peekTapAction = $0.rawValue }
                )) {
                    ForEach(PeekTapAction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                peekSeconds("AI 会话提示停留", \.peekSessionSeconds)
            } header: {
                Text("AI 会话提示")
            } footer: {
                Text("Claude Code / Codex 的会话跑完或在等你时，面板闭合就从刘海垂一条，点它跳回那个终端 / 展开到 AI 页。「等审批」「等输入」那两种比跑完多留 3 秒——真要人来的该多给点时间。提示条挂着的时候鼠标停上去不会展开面板，不然还没等你点它就被展开动作清掉了。")
            }
            Section {
                Toggle("摄像头 / 麦克风被占用时画点", isOn: preferenceToggle(\.privacyDots))
            } footer: {
                Text("只读设备的占用状态，不开流、不要权限。画在展开态标题行：摄像头绿、麦克风橙。")
            }
            Section {
                Text("AI 会话提示跟着 hook 走，没有单独开关：任一 Claude Code / Codex 会话跑完一个回合，面板闭合时弹一下。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 秒数直接输，2 到 30（超出范围提交时夹回来）。步进点半天不如敲两下键盘。
    private func peekSeconds(_ title: String, _ key: WritableKeyPath<Preferences, Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("", value: Binding(
                get: { PreferencesStore.shared.prefs[keyPath: key] },
                set: { PreferencesStore.shared.prefs[keyPath: key] = Preferences.peekSeconds($0) }
            ), format: .number)
            .multilineTextAlignment(.trailing)
            .frame(width: 44)
            Text("秒")
                .foregroundStyle(.secondary)
        }
    }
}

/// 文件架：开关、存放位置、清空。
struct ShelfSettings: View {
    var store = ShelfStore.shared

    var body: some View {
        Form {
            Section {
                Toggle("「文件架」页", isOn: preferenceToggle(\.shelfEnabled))
            } footer: {
                Text("把文件拖到刘海上就展开到文件架并暂存一份副本；从文件架拖出去、AirDrop、右键打开。副本保留 3 天后自动清理。关掉后不接拖放、不占内存，已暂存的文件留在磁盘上。")
            }
            Section {
                HStack {
                    Text("存放位置")
                    Spacer()
                    Text(store.directory.path)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([store.directory]) }
                }
                HStack {
                    Text("已暂存 \(store.items.count) 项")
                    Spacer()
                    Button("清空文件架", role: .destructive) { store.clear() }
                        .disabled(store.items.isEmpty)
                }
            }
        }
    }
}

/// hook：两侧安装状态。
struct HookSettings: View {
    var hooks = HookInstallModel.shared

    var body: some View {
        Form {
            Section {
                ForEach(HookSide.allCases, id: \.self) { side in
                    HookRow(side: side, hooks: hooks)
                }
            } footer: {
                Text("会话数据来自 Claude Code 和 Codex 的 hook（Cursor、Antigravity 没有 hook，只显示用量）。安装会改 ~/.claude/settings.json 与 ~/.codex/hooks.json，改前留 .tally-backup 备份；已经开着的会话要重开一次才会挂上。卸载 Tally 前先点「移除」把注册退掉。")
            }
        }
        .onAppear { hooks.refresh() }
    }
}

/// 用量：显示哪几家。
struct UsageSettings: View {
    var preferences = PreferencesStore.shared
    var usage = UsageStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(ProviderID.allCases) { provider in
                    Toggle(provider.displayName, isOn: providerBinding(provider))
                }
            } footer: {
                Text("关掉的提供方不读日志、不查接口。Claude 只读登录留下的 token，不刷新不回写。")
            }
        }
    }

    private func providerBinding(_ provider: ProviderID) -> Binding<Bool> {
        Binding(
            get: { preferences.prefs[keyPath: provider.enabledKey] },
            set: { enabled in
                preferences.prefs[keyPath: provider.enabledKey] = enabled
                usage.providersChanged()
            }
        )
    }
}

/// 一侧 hook 的状态行：状态文字 + 安装按钮，失败时展开原因与手工步骤。
struct HookRow: View {
    let side: HookSide
    var hooks: HookInstallModel

    var body: some View {
        let status = hooks.statuses[side]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(side.title)
                Spacer()
                Text(HookInstallModel.describe(status))
                    .font(.caption)
                    .foregroundStyle(status == .installed ? Color.green : Color.orange)
                    .lineLimit(1)
                Button(status == .installed ? "已安装" : "安装") { hooks.install(side) }
                    .disabled(status == .installed || hooks.busy.contains(side))
                if status != nil, status != .missing {
                    Button("移除") { hooks.uninstall(side) }
                        .disabled(hooks.busy.contains(side))
                }
            }
            if let error = hooks.errors[side] {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}
