import Foundation
import IOKit

/// 一次系统采样。每项都可空：采不到就是 nil，页面上那一项显示「—」。
struct SystemSample: Equatable {
    var memoryUsed: UInt64?
    var memoryTotal: UInt64?
    var swapUsed: UInt64?
    var swapTotal: UInt64?
    /// 0…1，第一次采样没有上一次的 tick 可比，为 nil。
    var cpuFraction: Double?
    /// 没电池为 nil。
    var battery: BatteryHealth?
    var diskAvailable: UInt64?
    var diskTotal: UInt64?
    /// 内核自己的内存压力判断。
    var pressure: MemoryPressure?
    /// 内存大户前三，按占用降序。
    var topProcesses: [ProcessMemory] = []

    enum Level: Equatable { case ok, warn, critical }

    var memoryLevel: Level? {
        guard let used = memoryUsed, let total = memoryTotal, total > 0 else { return nil }
        return Self.level(Double(used) / Double(total), warn: 0.75, critical: 0.90)
    }

    var cpuLevel: Level? {
        cpuFraction.map { Self.level($0, warn: 0.70, critical: 0.90) }
    }

    /// 看的是可用占比：不到 10% 红、不到 20% 黄。
    var diskLevel: Level? {
        guard let available = diskAvailable, let total = diskTotal, total > 0 else { return nil }
        let fraction = Double(available) / Double(total)
        if fraction < 0.10 { return .critical }
        if fraction < 0.20 { return .warn }
        return .ok
    }

    /// 充电中或已充满一律绿；放电 10% 以下红、20% 以下黄。
    var batteryLevel: Level? {
        guard let battery else { return nil }
        if battery.state != .discharging { return .ok }
        if battery.percent <= 10 { return .critical }
        if battery.percent <= 20 { return .warn }
        return .ok
    }

    private static func level(_ fraction: Double, warn: Double, critical: Double) -> Level {
        if fraction >= critical { return .critical }
        if fraction >= warn { return .warn }
        return .ok
    }
}

/// `kern.memorystatus_vm_pressure_level`：1 正常、2 偏紧、4 严重。
enum MemoryPressure: Equatable {
    case normal, warn, critical

    var label: String {
        switch self {
        case .normal: return "正常"
        case .warn: return "偏紧"
        case .critical: return "严重"
        }
    }

    init?(level: Int32) {
        switch level {
        case 1: self = .normal
        case 2: self = .warn
        case 4: self = .critical
        default: return nil
        }
    }
}

/// 一个进程的物理内存占用。
struct ProcessMemory: Equatable {
    var name: String
    var bytes: UInt64
}

/// 电池：电量与状态 2 秒一采，健康 = 当前最大容量 ÷ 设计容量。来源是 IOKit 注册表的 AppleSmartBattery，`ioreg` 就能看到，不是私有 API。
struct BatteryHealth: Equatable {
    enum State: Equatable {
        /// `onPower`：接着电源但没在充（优化充电停在 80% 那种），拔电判定靠 `externalConnected` 不靠它。
        case charging, full, onPower, discharging

        var label: String {
            switch self {
            case .charging: return "充电中"
            case .full: return "已充满"
            case .onPower: return "接电源"
            case .discharging: return "放电"
            }
        }
    }

    /// Apple Silicon 上 `CurrentCapacity` 本身就是百分比。
    var percent: Int
    var state: State
    var healthPercent: Int?
    var cycleCount: Int?
    /// 接着电源（不管在不在充）。
    var externalConnected = false

    /// 健康 ≥ 80% 绿、≥ 60% 黄、其余红。
    var healthLevel: SystemSample.Level? { Self.level(healthPercent) }

    static func level(_ healthPercent: Int?) -> SystemSample.Level? {
        healthPercent.map { $0 >= 80 ? .ok : ($0 >= 60 ? .warn : .critical) }
    }

    static func state(isCharging: Bool, externalConnected: Bool, percent: Int) -> State {
        if isCharging { return .charging }
        if externalConnected { return percent >= 95 ? .full : .onPower }
        return .discharging
    }

    /// 兜底算法：`AppleRawMaxCapacity ÷ DesignCapacity`。和「系统信息」对不上（本机 89% vs 93%），
    /// 因为系统那个数是平滑过的，不是这两个字段的直接比值——所以优先用 `systemReported()`，这个只在它取不到时顶上。
    static func health(rawMax: Int?, design: Int?) -> Int? {
        guard let rawMax, let design, design > 0 else { return nil }
        return Int((Double(rawMax) / Double(design) * 100).rounded())
    }

    /// 「系统信息 → 电源」显示的那个「最大容量」，直接问它自己的数据源（`SPPowerDataType` 的
    /// `sppower_battery_health_maximum_capacity`，形如 "93%"）。本机实测 0.15 秒，所以只在打开系统页时读一次。
    /// ioreg 里没有这个数：`AppleRawMaxCapacity/DesignCapacity` 得 89%、`NominalChargeCapacity/DesignCapacity` 得 91%，
    /// 都不是系统显示的 93%。
    nonisolated static func systemReported() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-xml", "SPPowerDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]],
              let items = plist.first?["_items"] as? [[String: Any]]
        else { return nil }
        for item in items {
            guard let info = item["sppower_battery_health_info"] as? [String: Any],
                  let text = info["sppower_battery_health_maximum_capacity"] as? String
            else { continue }
            return Int(text.replacingOccurrences(of: "%", with: ""))
        }
        return nil
    }

    static func read() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any],
              let percent = dict["CurrentCapacity"] as? Int else { return nil }
        let externalConnected = dict["ExternalConnected"] as? Bool ?? false
        return BatteryHealth(
            percent: percent,
            state: state(isCharging: dict["IsCharging"] as? Bool ?? false, externalConnected: externalConnected, percent: percent),
            healthPercent: health(rawMax: dict["AppleRawMaxCapacity"] as? Int, design: dict["DesignCapacity"] as? Int),
            cycleCount: dict["CycleCount"] as? Int,
            externalConnected: externalConnected
        )
    }
}

/// 一次性读的硬件信息。
struct HardwareInfo: Equatable {
    var chip: String
    var performanceCores: Int
    /// Intel 没有能效核，为 nil。
    var efficiencyCores: Int?
    var memoryTotal: UInt64
    var osVersion: String
    var bootTime: Date

    /// 「16（12 性能 + 4 能效）」，Intel 只写「8」。
    var coresText: String {
        guard let efficiencyCores else { return "\(performanceCores)" }
        return "\(performanceCores + efficiencyCores)（\(performanceCores) 性能 + \(efficiencyCores) 能效）"
    }

    /// 满一天「1 天 13 小时」，不满一天「13 小时 5 分钟」，不满一小时「5 分钟」。
    static func uptimeText(from boot: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(boot)) / 60)
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        let rest = minutes % 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(rest) 分钟" }
        return "\(rest) 分钟"
    }

    /// 「26.2」，补丁号非 0 才带。
    static func versionText(_ v: OperatingSystemVersion) -> String {
        v.patchVersion == 0 ? "\(v.majorVersion).\(v.minorVersion)" : "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func read() -> HardwareInfo? {
        guard let chip = SystemSampler.sysctlString("machdep.cpu.brand_string"),
              let memory = SystemSampler.sysctlUInt64("hw.memsize") else { return nil }
        let performance = SystemSampler.sysctlInt32("hw.perflevel0.physicalcpu") ?? SystemSampler.sysctlInt32("hw.physicalcpu") ?? 0
        let efficiency = SystemSampler.sysctlInt32("hw.perflevel1.physicalcpu")
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let bootTime = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0
            ? Date(timeIntervalSince1970: Double(boot.tv_sec)) : Date()
        return HardwareInfo(
            chip: chip,
            performanceCores: Int(performance),
            efficiencyCores: efficiency.map(Int.init),
            memoryTotal: memory,
            osVersion: versionText(ProcessInfo.processInfo.operatingSystemVersion),
            bootTime: bootTime
        )
    }
}

/// 全公开 API：host_statistics64、sysctl、host_processor_info、IOKit 注册表、URL 资源值。
/// 每项一个函数，各自失败互不影响。CPU 要两次采样做差分，所以是 mutating。
struct SystemSampler {
    private var previousTicks: [UInt32]?

    mutating func sample() -> SystemSample {
        var s = SystemSample()
        if let memory = Self.memory() {
            s.memoryUsed = memory.used
            s.memoryTotal = memory.total
        }
        if let swap = Self.swap() {
            s.swapUsed = swap.used
            s.swapTotal = swap.total
        }
        s.cpuFraction = cpu()
        s.battery = BatteryHealth.read()
        if let disk = Self.disk() {
            s.diskAvailable = disk.available
            s.diskTotal = disk.total
        }
        s.pressure = Self.sysctlInt32("kern.memorystatus_vm_pressure_level").flatMap(MemoryPressure.init(level:))
        s.topProcesses = Self.topProcesses(limit: 3)
        return s
    }

    /// 遍历所有 pid 读 `ri_phys_footprint`，和活动监视器「内存」列同口径。几百个进程几毫秒。
    static func topProcesses(limit: Int) -> [ProcessMemory] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        var rows: [ProcessMemory] = []
        rows.reserveCapacity(count)
        for pid in pids.prefix(count) where pid > 0 {
            guard let bytes = footprint(pid: pid) else { continue }
            rows.append(ProcessMemory(name: processName(pid), bytes: bytes))
        }
        return Array(rows.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    /// 一个进程的物理内存（`ri_phys_footprint`），读不到或为 0 返回 nil。
    static func footprint(pid: pid_t) -> UInt64? {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
        }
        guard status == 0, info.ri_phys_footprint > 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// Claude Code 的进程短名是版本号（可执行文件叫 2.1.263），按路径认出来。
    static func processName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let name = String(cString: buffer)
        guard !name.isEmpty else { return "pid \(pid)" }
        guard name.allSatisfy({ $0.isNumber || $0 == "." }) else { return name }
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        proc_pidpath(pid, &path, UInt32(path.count))
        return String(cString: path).contains("/claude/") ? "claude" : name
    }

    /// 已用 = (active + wired + compressed) × 页大小，和活动监视器的口径一致。
    static func memory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, let total = sysctlUInt64("hw.memsize") else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
        return (used, total)
    }

    static func swap() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// 所有核的 tick 拍平成 [user, system, idle, nice, user, system, …]，差分后算忙碌占比。
    private mutating func cpu() -> Double? {
        guard let ticks = Self.cpuTicks() else { return nil }
        defer { previousTicks = ticks }
        guard let previous = previousTicks else { return nil }
        return Self.cpuFraction(previous: previous, current: ticks)
    }

    static func cpuFraction(previous: [UInt32], current: [UInt32]) -> Double? {
        guard previous.count == current.count, current.count % 4 == 0 else { return nil }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for core in stride(from: 0, to: current.count, by: 4) {
            let user = UInt64(current[core] &- previous[core])
            let system = UInt64(current[core + 1] &- previous[core + 1])
            let idle = UInt64(current[core + 2] &- previous[core + 2])
            let nice = UInt64(current[core + 3] &- previous[core + 3])
            busy += user + system + nice
            total += user + system + nice + idle
        }
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }

    private static func cpuTicks() -> [UInt32]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        // CPU_STATE_USER=0, SYSTEM=1, IDLE=2, NICE=3，正好是 host 给的顺序
        return (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
    }

    static func disk() -> (available: UInt64, total: UInt64)? {
        let keys: Set<URLResourceKey> = [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let available = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity else { return nil }
        return (UInt64(max(0, available)), UInt64(max(0, total)))
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
