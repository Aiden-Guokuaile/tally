import Foundation
import Observation
import UserNotifications

/// 没有刘海屏（合盖接外接屏）时提示条画不出来，会话、配额、文件架提示改发系统通知。
/// 授权到真要发的那一刻才请求：一直用内建屏的人永远不会被问。
@MainActor
@Observable
final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {

    static let shared = SystemNotifier()

    nonisolated static let deniedText = "系统通知没被允许，没有刘海屏时的提醒发不出去：去「系统设置 → 通知 → Tally」打开"

    /// 点了会话通知：参数是 session_id，控制器接去跳终端。
    @ObservationIgnored var onTapSession: ((String) -> Void)?
    /// 拒过通知时的说明，设置页显示：这条路本来就是提示条画不出来时才走的，拒了就什么提醒都没有，不能只记日志。
    private(set) var problem: String?

    /// 不在 init 里碰 `UNUserNotificationCenter`：测试进程（xctest）没有 bundle id，一碰就崩。
    func post(_ peek: Peek) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = "\(peek.label) · \(peek.title)"
        content.body = peek.subtitle ?? ""
        if let sessionId = peek.sessionId { content.userInfo = ["sessionId": sessionId] }
        let request = UNNotificationRequest(identifier: peek.id, content: content, trigger: nil)
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            Task { @MainActor in self?.problem = granted ? nil : Self.deniedText }
            guard granted else {
                Log.error("系统通知没有授权，提醒没发出去: \(error?.localizedDescription ?? "用户没允许")")
                return
            }
            center.add(request) { error in
                if let error { Log.error("系统通知发送失败: \(error.localizedDescription)") }
            }
        }
    }

    /// 设置页打开时看一眼授权：拒过就亮出来。还没问过（notDetermined）不算问题。
    func refreshStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in self?.problem = denied ? Self.deniedText : nil }
        }
    }

    /// 前台也弹横幅：Tally 是附件型 app，设置窗口开着时系统会把它当前台，默认就不弹了。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sessionId = response.notification.request.content.userInfo["sessionId"] as? String {
            Task { @MainActor in self.onTapSession?(sessionId) }
        }
        completionHandler()
    }
}
