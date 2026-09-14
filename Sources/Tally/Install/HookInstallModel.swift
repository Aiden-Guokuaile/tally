import Foundation
import Observation

/// 设置页「hook」两行的状态与动作。安装是用户点了按钮才做，Codex 那侧要跑 app-server，放后台。
@MainActor
@Observable
final class HookInstallModel {

    static let shared = HookInstallModel(installer: HookInstaller.live())

    private(set) var statuses: [HookSide: HookStatus] = [:]
    private(set) var busy: Set<HookSide> = []
    private(set) var errors: [HookSide: String] = [:]

    let installer: HookInstaller

    init(installer: HookInstaller) {
        self.installer = installer
    }

    func refresh() {
        for side in HookSide.allCases {
            statuses[side] = installer.status(side)
        }
    }

    func install(_ side: HookSide) {
        guard !busy.contains(side) else { return }
        busy.insert(side)
        errors[side] = nil
        let installer = self.installer
        Task.detached {
            let failure: String?
            do {
                try installer.install(side)
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run {
                self.busy.remove(side)
                if let failure {
                    self.errors[side] = failure + "\n" + HookInstaller.manualSteps(side, hookBinary: installer.hookBinary)
                }
                self.refresh()
            }
        }
    }

    /// 移除注册；Codex 侧还要重写别的 hook 的信任哈希，放后台。
    func uninstall(_ side: HookSide) {
        guard !busy.contains(side) else { return }
        busy.insert(side)
        errors[side] = nil
        let installer = self.installer
        Task.detached {
            let failure: String?
            do {
                try installer.uninstall(side)
                failure = nil
            } catch {
                failure = "移除时出错：" + error.localizedDescription
            }
            await MainActor.run {
                self.busy.remove(side)
                if let failure { self.errors[side] = failure }
                self.refresh()
            }
        }
    }

    /// `--install-hooks` 启动参数用：同步装两侧，返回每侧的结果文本。
    func installAllBlocking() -> [String] {
        HookSide.allCases.map { side in
            do {
                try installer.install(side)
                return "\(side.title): \(Self.describe(installer.status(side)))"
            } catch {
                return "\(side.title): 失败 \(error.localizedDescription)"
            }
        }
    }

    static func describe(_ status: HookStatus?) -> String {
        switch status {
        case .installed: return "已安装"
        case .missing: return "未安装"
        case .pointsElsewhere(let why): return "需要更新（\(why)）"
        case nil: return "未知"
        }
    }
}
