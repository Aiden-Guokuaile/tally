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
    var updates = UpdateChecker.shared
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
                Toggle("检查新版本", isOn: preferenceToggle(\.checkUpdates))
                if let release = updates.available {
                    HStack {
                        Text("有新版本 \(release.version)")
                            .foregroundStyle(.blue)
                        Spacer()
                        if UpdateChecker.installedByHomebrew() {
                            Text("brew upgrade --cask tally")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        } else {
                            Button("去下载") { NSWorkspace.shared.open(release.page) }
                        }
                    }
                } else if let problem = updates.problem {
                    Text(problem).foregroundStyle(.orange).font(.caption)
                } else if let checked = updates.lastChecked {
                    Text("已是最新 · 上次检查 \(checked.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if preferences.prefs.checkUpdates {
                    Button("现在检查") { Task { await updates.check() } }
                        .disabled(updates.checking)
                }
            } footer: {
                Text("每天问一次 GitHub 上的最新版本（api.github.com，不带任何账号信息），有新的就在这里和刘海里各说一声。只提示，不自动下载替换：用 Homebrew 装的执行 brew upgrade --cask tally，其余去下载新的 DMG。")
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
                Toggle("全屏 app 时隐藏面板", isOn: preferenceToggle(\.hideInFullScreen))
            } header: {
                Text("开合")
            } footer: {
                Text("悬停展开关了就只剩 \(HotKeyCenter.label)。展开后两指横滑或三指轻扫翻页。\n\n「全屏 app 时隐藏面板」：视频、演示、游戏这类全屏 app 里整个刘海面板不出现，提示条也看不到（提示音照响），退出全屏就回来。只认系统的全屏（绿色按钮、⌃⌘F），自己铺满屏幕的无边框窗口不算。")
            }
            Section {
                Toggle("数字键 1–9 切到第 N 个页签", isOn: preferenceToggle(\.pageNumberKeys))
                Toggle("⌘1–⌘5 跳到第 N 个会话的终端", isOn: preferenceToggle(\.sessionCommandKeys))
            } header: {
                Text("键盘")
            } footer: {
                Text("只在面板展开时有效：展开时键盘归面板，收起后数字和 ⌘N 照常打进原来的 app。会话按 AI 页列表的显示顺序数（「等你」那组排最前），按住 ⌘ 时前五行行尾会显示编号；跳过去和点那一行一样，接着打字进的就是那个终端，面板等鼠标移出再收。")
            }
            Section {
                Toggle("保留已关闭的会话", isOn: preferenceToggle(\.keepClosedSessions))
            } header: {
                Text("会话列表")
            } footer: {
                Text("会话结束或终端关掉后，在 AI 页「最近」里留一行「已关闭」，点它或按对应的 ⌘N 在新终端里接着聊（claude --resume / codex resume）。只留在终端里开的交互会话，claude -p、codex exec 这类脚本跑的不留；最多留最新 5 条。关掉后已有的在下一次刷新列表时清掉。")
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
                Toggle("提示音", isOn: preferenceToggle(\.sessionSound))
            } header: {
                Text("AI 会话提示")
            } footer: {
                Text("Claude Code / Codex 的会话跑完或在等你时，面板闭合就从刘海垂一条，点它跳回那个终端 / 展开到 AI 页。「等审批」「等输入」那两种比跑完多留 3 秒——真要人来的该多给点时间。提示条挂着的时候鼠标停上去不会展开面板，不然还没等你点它就被展开动作清掉了。跑完响 Glass，在等你响 Ping。那个会话的终端标签正在前台时（Ghostty / Terminal / iTerm，且已经允许 Tally 控制它）不响也不弹：你正看着它。")
            }
            Section {
                Toggle("配额涨过 80%、用完、重置时提示", isOn: preferenceToggle(\.quotaPeek))
            } footer: {
                Text("每个配额窗口从 80% 以下涨到 80% 以上、涨到用完各提醒一次，用过 80% 的窗口重置了再说一声；开 Tally 时已经很高的不补报。提示条不可点，停留时长和 AI 会话提示一样。")
            }
            Section {
                Toggle("没有刘海屏时改发系统通知", isOn: preferenceToggle(\.notifyWithoutNotch))
                if let problem = SystemNotifier.shared.problem {
                    Text(problem).foregroundStyle(.red).font(.caption)
                }
            } footer: {
                Text("合盖接外接屏时刘海面板不在，会话跑完 / 在等你、配额、文件架的提示改成系统通知（电池的不发）；点会话通知跳回那个终端。第一次要发的时候系统会问一次通知权限。")
            }
            Section {
                Toggle("摄像头 / 麦克风被占用时画点", isOn: preferenceToggle(\.privacyDots))
            } footer: {
                Text("只读设备的占用状态，不开流、不要权限。画在展开态标题行：摄像头绿、麦克风橙。")
            }
            Section {
                Text("AI 会话提示跟着 hook 走，没有单独开关（提示音可以关）：任一 Claude Code / Codex 会话跑完一个回合或在等你，面板闭合时弹一下。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { SystemNotifier.shared.refreshStatus() }
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
    var preferences = PreferencesStore.shared
    var screenshots = ScreenshotWatcher.shared

    var body: some View {
        Form {
            Section {
                Toggle("「文件架」页", isOn: preferenceToggle(\.shelfEnabled))
            } footer: {
                Text("把文件拖到刘海上就展开到文件架并暂存一份副本；从文件架拖出去、AirDrop、右键打开。副本保留 3 天后自动清理。关掉后不接拖放、不占内存，已暂存的文件留在磁盘上。脚本里 open -a Tally <文件> 也能放进来。")
            }
            Section {
                Toggle("新截图自动放进文件架", isOn: screenshotsBinding)
                    .disabled(!preferences.prefs.shelfEnabled)
                if preferences.prefs.screenshotsToShelf, let folder = preferences.prefs.screenshotFolder {
                    HStack {
                        Text("截图文件夹")
                        Spacer()
                        Text(folder)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("换一个") { chooseScreenshotFolder() }
                    }
                }
                if let problem = screenshots.problem {
                    Text(problem).foregroundStyle(.red).font(.caption)
                }
            } footer: {
                Text("截图（⌘⇧3 / ⌘⇧4 / ⌘⇧5）一落进截图文件夹就复制一份到文件架，好直接拖进 Claude Code / Codex。认的是系统写在截图文件上的标记，不看文件名；只收打开之后的新截图。打开时要在选择面板里点一下截图文件夹（系统默认是桌面）：桌面受隐私保护，点过这一下 Tally 才读得到它，不会再弹别的框。")
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

    /// 打开时还没选过文件夹就先选；选择面板点了取消就不开。
    private var screenshotsBinding: Binding<Bool> {
        Binding(
            get: { preferences.prefs.screenshotsToShelf },
            set: { on in
                if on, preferences.prefs.screenshotFolder == nil, !chooseScreenshotFolder() { return }
                preferences.prefs.screenshotsToShelf = on
            }
        )
    }

    /// 选截图文件夹，默认指到系统截图位置。用户在面板里点选这一下，就是读桌面这类受保护目录的授权。返回选没选。
    @discardableResult
    private func chooseScreenshotFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = ScreenshotWatcher.systemLocation()
        panel.prompt = "用这个文件夹"
        panel.message = "选截图保存的文件夹（系统默认是桌面）"
        guard NotchPanel.steppingAside({ panel.runModal() }) == .OK, let url = panel.url else { return false }
        preferences.prefs.screenshotFolder = url.path
        return true
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
                Text("会话数据来自 Claude Code 和 Codex 的 hook（Cursor、Antigravity 没有 hook，只显示用量）。安装会改 ~/.claude/settings.json 与 ~/.codex/hooks.json，改前留 .tally-backup 备份；已经开着的会话要重开一次才会挂上。卸载 Tally 前先点「移除」把注册退掉。\n\n每侧下面一行是 hook 最近一次收到事件的时间，一直「还没收到过」说明 agent 没在调它。「自检」拿装好的 tally-hook 跑一条模拟事件，看它本身能不能跑、能不能写出状态文件。")
            }
        }
        .onAppear { hooks.refresh() }
    }
}

/// 用量：显示哪几家；国内几家与 New API 的凭据。
struct UsageSettings: View {
    var preferences = PreferencesStore.shared
    var usage = UsageStore.shared
    var credentials = ProviderCredentialsStore.shared

    /// 这四家的凭据全从各自工具的登录里读，只有开关。
    private static let builtIn: [ProviderID] = [.claude, .codex, .cursor, .antigravity]

    var body: some View {
        Form {
            Section {
                ForEach(Self.builtIn) { provider in
                    Toggle(provider.displayName, isOn: providerBinding(provider))
                }
            } footer: {
                Text("关掉的提供方不读日志、不查接口。Claude 只读登录留下的 token，不刷新不回写。")
            }
            if let saveError = credentials.saveError {
                Section {
                    Text(saveError).foregroundStyle(.red).font(.caption)
                }
            }
            Section {
                Toggle("DeepSeek", isOn: providerBinding(.deepseek))
                source(DeepSeekUsageProvider.describeCredentials(credentials.credentials))
                SecureField("API key（sk-…）", text: field(\.deepseekKey))
                refetchButton(.deepseek)
            } header: {
                Text("DeepSeek")
            } footer: {
                Text("查账户余额，人民币和美元分开显示。Claude Code 里已经把 DeepSeek 配成 ANTHROPIC_BASE_URL 的，不用再填。")
            }
            Section {
                Toggle("Kimi", isOn: providerBinding(.kimi))
                source(KimiUsageProvider.describeCredentials(credentials.credentials))
                SecureField("Kimi Code key（sk-kimi-…，查会员配额）", text: field(\.kimiCodeKey))
                SecureField("开放平台 key（查余额）", text: field(\.moonshotKey))
                region(\.moonshotRegion, china: "国内 moonshot.cn", international: "国际 moonshot.ai")
                refetchButton(.kimi)
            } header: {
                Text("Kimi")
            } footer: {
                Text("Kimi Code 会员的 5 小时 / 周配额，加开放平台余额，有哪样查哪样。登录过 Kimi Code CLI、或在 Claude Code 里配了 Kimi 的，不用再填。国内和国际两个区的账号不通：key 在哪个区申请的就选哪个。")
            }
            Section {
                Toggle("GLM Coding Plan", isOn: providerBinding(.glm))
                source(GLMUsageProvider.describeCredentials(credentials.credentials))
                SecureField("API key", text: field(\.glmKey))
                region(\.glmRegion, china: "国内 bigmodel.cn", international: "国际 z.ai")
                refetchButton(.glm)
            } header: {
                Text("智谱 GLM")
            } footer: {
                Text("GLM Coding Plan 的 5 小时 / 周配额。Claude Code、zcode、opencode 里配过的会自动找到。这个配额接口智谱没有公开文档，改版后可能读不到。")
            }
            Section {
                Toggle("New API 中转站", isOn: providerBinding(.newapi))
                source(NewAPIUsageProvider.describeCredentials(credentials.credentials))
                TextField("站点地址（https://…）", text: field(\.newapiBaseURL))
                SecureField("访问令牌", text: field(\.newapiToken))
                TextField("用户 ID", text: field(\.newapiUserId))
                refetchButton(.newapi)
            } header: {
                Text("New API")
            } footer: {
                Text("One API / New API 搭的中转站余额。访问令牌在站点「个人设置」里生成，和调模型用的 sk- 令牌不是一个东西；用户 ID 在同一页。")
            }
            Section {
                Text("手填的 key 只存在本机 ~/Library/Application Support/Tally/providers.json（只有你能读），不进钥匙串；只发给对应那一家的官方接口（New API 发给你填的站点）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 现在用的是哪份凭据，或者还缺什么。
    private func source(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func field(_ key: WritableKeyPath<ProviderCredentials, String>) -> Binding<String> {
        Binding(
            get: { credentials.credentials[keyPath: key] },
            set: { credentials.credentials[keyPath: key] = $0 }
        )
    }

    private func region(_ key: WritableKeyPath<ProviderCredentials, String>, china: String, international: String) -> some View {
        Picker("区", selection: field(key)) {
            Text(china).tag("cn")
            Text(international).tag("intl")
        }
        .pickerStyle(.segmented)
    }

    /// 改完凭据不用等下一轮（最长 5 分钟）：只重查这一家。
    private func refetchButton(_ provider: ProviderID) -> some View {
        Button("现在查一次") { usage.refetch(provider) }
            .disabled(!preferences.prefs[keyPath: provider.enabledKey])
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
            HStack {
                Text(HookInstallModel.describeHeartbeat(hooks.heartbeats[side], now: Date()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("自检") { hooks.selfTest(side) }
                    .disabled(hooks.busy.contains(side))
            }
            if let result = hooks.selfTests[side] {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("正常") ? Color.green : Color.orange)
                    .textSelection(.enabled)
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
