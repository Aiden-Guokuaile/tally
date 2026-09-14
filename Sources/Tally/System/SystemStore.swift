import Foundation
import Observation

/// 系统页的状态：硬件信息第一次展开时读一次；动态指标面板展开时每 2 秒采一次，收起就停。
@MainActor
@Observable
final class SystemStore {

    static let shared = SystemStore()

    private(set) var hardware: HardwareInfo?
    private(set) var sample = SystemSample()
    /// 「系统信息」口径的电池最大容量。取不到就用采样里那个比值兜底。
    private(set) var batteryHealthPercent: Int?
    /// 展开时和清空后各扫一次；nil 是还没扫完。
    private(set) var trash: TrashInfo?
    /// 清空后短暂显示的结果。
    private(set) var trashMessage: String?
    private(set) var emptying = false

    private var sampler = SystemSampler()
    private var timer: Timer?
    /// 扫描与清空都是后台任务，晚回来的旧一轮不能盖住新一轮。
    private var trashGeneration = 0

    func start() {
        guard timer == nil else { return }
        if hardware == nil { hardware = HardwareInfo.read() }
        readBatteryHealth()
        scanTrash()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        Log.debug("系统采样停止")
    }

    /// 标题行的刷新按钮：硬件重读一次（开机时长会变）、动态指标重采、废纸篓重扫。
    func refreshNow() {
        guard timer != nil else { return }
        hardware = HardwareInfo.read()
        readBatteryHealth()
        tick()
        scanTrash()
    }

    private func tick() {
        sample = sampler.sample()
    }

    /// 健康度要 spawn 一次 system_profiler（0.15 秒），别挡主线程；健康度变化以天计，读一次就够。
    private func readBatteryHealth() {
        Task.detached(priority: .utility) {
            let percent = BatteryHealth.systemReported()
            await MainActor.run { if let percent { self.batteryHealthPercent = percent } }
        }
    }

    /// 大废纸篓要走几秒，放后台。
    func scanTrash() {
        trashGeneration += 1
        let mine = trashGeneration
        Task.detached(priority: .utility) {
            let info = TrashInfo.scan()
            await MainActor.run {
                guard self.trashGeneration == mine else { return }
                self.trash = info
            }
        }
    }

    /// 调用方已经确认过了；这里只管删、再扫、报结果。
    func emptyTrash() {
        guard !emptying else { return }
        emptying = true
        trashGeneration += 1
        let mine = trashGeneration
        Task.detached(priority: .userInitiated) {
            let result = TrashInfo.empty()
            let info = TrashInfo.scan()
            await MainActor.run {
                self.emptying = false
                guard self.trashGeneration == mine else { return }
                self.trash = info
                self.trashMessage = result.failed == 0 ? "已清空 \(result.removed) 项" : "删了 \(result.removed) 项，\(result.failed) 项失败"
            }
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run { if self.trashGeneration == mine { self.trashMessage = nil } }
        }
    }
}
