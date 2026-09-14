import Foundation
import Observation

/// 合盖也不休眠：置内核的 `SleepDisabled`（`pmset -a disablesleep 1`），要 root。
///
/// 为什么不能靠电源断言：`KeepAwake` 那个断言只挡**闲置**休眠，合盖触发的是 clamshell 休眠，低一层，
/// `caffeinate -d/-i/-s` 和任何 `IOPMAssertion` 都拦不住——没接外接屏时合盖必睡。不接屏还要合盖继续跑，
/// 只有内核这个开关。
///
/// **拿 root 的方式只有免密规则这一条**：往 `/etc/sudoers.d/tally` 装一条只管几条命令的 NOPASSWD 规则，
/// 一次密码，以后（跨重启、跨重装）都不再问。试过「每次开都走 `do shell script … with administrator
/// privileges`，顺带在授权里起个 root 看门狗负责恢复」——**授权层起的后台进程当场就被杀**（实测：pid 记下来了，
/// 进程不存在，一行日志都没写出来），于是恢复路径全是哑的：关掉开关、退出 app，系统里那个开关还开着，
/// 机器再也不休眠而界面显示是关的。有了免密就不需要看门狗了，Tally 自己置位、自己恢复。
///
/// 唯一恢复不了的路是 Tally 被 `SIGKILL` 或断电：`SleepDisabled` 是持久设置，重启也留着，
/// 所以启动时 `checkResidue()` 读一次真实状态，是 1 而不是自己开的就直接抹掉（免密，不弹框）。
/// Tally 是登录项，这个窗口最长到下次登录。
@MainActor
@Observable
final class LidSleepBlocker {

    static let shared = LidSleepBlocker()

    nonisolated static let sudoersPath = "/etc/sudoers.d/tally"

    private(set) var isActive = false

    /// 免密规则装没装。以 `sudo -n -l` 的实际结果为准，不看文件在不在——规则生效还得 sudoers 真的 include 了那个目录。
    private(set) var passwordless = false

    /// 系统里还开着、又不是这一轮开的，而且没免密规则可用（清它要一次密码）。
    private(set) var residue = false

    /// 上一次失败的原因，界面上要说出来。人点取消不算失败，这里是 nil。
    /// 装规则要管理员账号，别人拿到这个 app 时最常见的失败就是这条，不说的话就是「点了没反应」。
    private(set) var failure: String?

    // MARK: 开关

    /// 开：没装规则就先装（这一次要密码），然后置位。
    /// 保持唤醒没开就一起开——`SleepDisabled` 只挡合盖，闲置休眠仍旧归断言管。
    func enable() async -> Bool {
        failure = nil
        // 演示模式只亮开关：装免密规则要弹管理员密码框（setDisableSleep 那边同样不跑 sudo）
        if !passwordless, !DemoMode.isOn, !(await installPasswordless()) { return false }
        guard Self.setDisableSleep(true) else {
            refreshPasswordless()
            failure = "pmset 没执行成功，免密规则可能被删了"
            return false
        }
        if !KeepAwake.shared.isActive {
            KeepAwake.shared.start(minutes: nil, keepDisplay: PreferencesStore.shared.prefs.keepAwakeDisplay)
        }
        isActive = true
        residue = false
        return true
    }

    /// 关：立刻抹回去，不弹框。退出 app 时也走这里。
    func disable() {
        guard isActive else { return }
        isActive = false
        _ = Self.setDisableSleep(false)
    }

    // MARK: 残留

    /// 启动时读一次真实状态：是 1 而不是这一轮开的，就是上一轮被强杀 / 断电留下的。
    /// 有免密就直接抹掉，没有就交给界面出一行橙字加「恢复」（那一下要密码）。
    func checkResidue() {
        refreshPasswordless()
        guard !isActive, Self.readSleepDisabled() else { return }
        if passwordless, Self.setDisableSleep(false) {
            Log.debug("上一轮留下的合盖不休眠已抹掉")
            return
        }
        residue = true
    }

    /// 界面上那颗「恢复」：没免密规则时要一次密码。
    func clearResidue() async -> Bool {
        guard await Self.runAuthorized("/usr/bin/pmset -a disablesleep 0") == .ok else { return false }
        residue = false
        return true
    }

    // MARK: 免密规则

    /// 装规则要一次密码。先写临时文件、`visudo -c` 验过语法再 `install` 到位——写坏 sudoers 会把整个 `sudo` 搞挂。
    /// 规则里顺带放行「删掉这个文件自己」，撤销时就不用再输一次密码；放行删掉自己这条授权不扩大任何权限。
    func installPasswordless() async -> Bool {
        failure = nil
        switch await Self.runAuthorized(Self.sudoersInstallScript(user: NSUserName())) {
        case .cancelled:
            return false
        case .failed:
            failure = "没能装上免密规则：这一步要管理员账号"
            return false
        case .ok:
            break
        }
        refreshPasswordless()
        if !passwordless {
            failure = "规则装上了却没生效：/etc/sudoers 里可能没有 @includedir /etc/sudoers.d"
        }
        return passwordless
    }

    /// 撤销：先把开着的关掉，再删规则（规则自己允许免密删自己，删不动才退回要密码那条路）。
    func removePasswordless() async -> Bool {
        disable()
        if !Self.run("/usr/bin/sudo", ["-n", "/bin/rm", "-f", Self.sudoersPath]) {
            guard await Self.runAuthorized("/bin/rm -f \(Self.sudoersPath)") == .ok else { return false }
        }
        refreshPasswordless()
        return !passwordless
    }

    func refreshPasswordless() {
        passwordless = Self.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])
    }

    // MARK: 底下这几件

    /// 免密置位 / 抹掉。命令必须和 sudoers 里写的逐字一致，否则免密不生效、静默失败。
    private static func setDisableSleep(_ on: Bool) -> Bool {
        // 演示模式当作成了：开关照亮、照灭，系统级的合盖设置一点不动
        guard !DemoMode.isOn else { return true }
        let ok = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
        if !ok { Log.error("pmset -a disablesleep \(on ? 1 : 0) 没成功，免密规则可能不在了") }
        return ok
    }

    nonisolated static func sudoersInstallScript(user: String) -> String {
        """
        T=$(/usr/bin/mktemp) || exit 1
        /bin/cat > "$T" <<'TALLYRULE'
        # Tally：合盖也不休眠用的免密规则，只放行这几条命令。删掉这个文件即撤销。
        \(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /bin/rm -f \(sudoersPath)
        TALLYRULE
        /usr/sbin/visudo -cf "$T" >/dev/null 2>&1 || { /bin/rm -f "$T"; exit 1; }
        /usr/bin/install -m 440 -o root -g wheel "$T" \(sudoersPath) || { /bin/rm -f "$T"; exit 1; }
        /bin/rm -f "$T"
        """
    }

    /// `pmset -g` 里开着时有一行 `SleepDisabled\t\t1`，关着是 0，从没设过就整行不出现。
    /// **分隔符是制表符不是空格**（`od -c` 实测）：只按空格切的话整行成一个字段，永远判成没开——
    /// 于是残留既不自动抹也不报警，界面上什么都看不出来。
    nonisolated static func sleepDisabled(inPmsetOutput text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[0] == "SleepDisabled" && fields[1] == "1"
        }
    }

    private static func readSleepDisabled() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
        } catch {
            Log.error("pmset -g 跑不起来: \(error.localizedDescription)")
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return sleepDisabled(inPmsetOutput: String(decoding: data, as: UTF8.self))
    }

    /// 跑一个命令，只关心成没成。输出全丢掉。
    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            Log.error("\(path) 跑不起来: \(error.localizedDescription)")
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    /// 脚本 base64 进 `do shell script`：AppleScript 那层字符串里只剩 base64 字符，不用套两层引号。
    ///
    /// **必须放后台跑**，理由同 `TerminalLocator.runAppleScript`：`executeAndReturnError` 是同步的，
    /// 放主线程上会在密码框弹着的时候把整个面板冻死。用 in-process 的 `NSAppleScript` 而不是起 `osascript`，
    /// 密码框上写的才是「Tally 想要进行更改」；起 osascript 的话人看到的是「osascript 想要进行更改」，谁都不敢输。
    ///
    /// 只用来干**一次就结束**的事（装 / 删规则、抹残留）。别指望在这里面起长期进程：授权层退出时会把后台进程一起杀掉。
    private static func runAuthorized(_ script: String) async -> AuthResult {
        let encoded = Data(script.utf8).base64EncodedString()
        let source = "do shell script \"/bin/echo \(encoded) | /usr/bin/base64 -D | /bin/sh\" with administrator privileges"
        return await Task.detached(priority: .userInitiated) { () -> AuthResult in
            var error: NSDictionary?
            guard let apple = NSAppleScript(source: source) else { return .failed }
            apple.executeAndReturnError(&error)
            guard let error else { return .ok }
            // -128 是人点了取消，不是错，界面上也不该报错
            guard (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue != -128 else { return .cancelled }
            Log.error("合盖不休眠授权失败: \(error)")
            return .failed
        }.value
    }

    /// 取消和失败要分开：取消是人的选择，界面不该报错；失败得说出来，否则点了没反应没人知道为什么。
    private enum AuthResult { case ok, cancelled, failed }
}
