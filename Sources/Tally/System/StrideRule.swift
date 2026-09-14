import Foundation

/// 菜单栏小恐龙的四个状态，素材是 Stride 定稿的逐帧图（`Resources/stride/{dark,light}/<状态>-NN.png`）。
enum StrideMood: String, CaseIterable {
    case sleep, run, sprint, angry

    var frameCount: Int { self == .angry ? 12 : 8 }

    /// 由低到高，判「往下降」用。
    var rank: Int {
        switch self {
        case .sleep: return 0
        case .run: return 1
        case .sprint: return 2
        case .angry: return 3
        }
    }

    /// 第 N 帧（从 0 数）的资源名：`run-03`。
    func frameName(_ index: Int) -> String {
        "\(rawValue)-" + String(format: "%02d", index + 1)
    }
}

/// 状态判定、帧率与蛋的颜色档，全是纯函数。
enum StrideRule {

    /// CPU（所有核汇总，0…1）进跑步、冲刺、生气的门槛。本机实测：几个 agent 会话在跑时整机 9%–20%、编译时 50% 以上。
    /// 生气的门槛放在碰得到的地方——贴着 100% 的话一年见不到一次。
    static let cpuRun = 0.10
    static let cpuSprint = 0.30
    static let cpuAngry = 0.60

    /// 内存已用（0…1）进冲刺、生气的门槛，也是蛋变橙、变红裂开的线。内存占用平时几乎不动（48 GB 机器 90 秒内 44%–50%），
    /// 拿它分睡觉和跑步的话，门槛放 40% 恐龙一直跑、放 60% 一直睡，所以内存只在吃紧时往上顶。
    static let memorySprint = 0.70
    static let memoryAngry = 0.85

    /// 往下降要比当前状态的门槛再低这么多：读数在门槛附近抖的时候不来回闪。
    static let hysteresis = 0.05

    /// 这一刻该是哪个状态：CPU 和内存各算一档取更忙的；内核说内存偏紧或严重一律生气。
    /// 往上立刻升；往下要两项都比当前状态的门槛再低 `hysteresis` 才降。
    static func resolve(cpu: Double, memory: Double, pressure: MemoryPressure?, previous: StrideMood) -> StrideMood {
        if let pressure, pressure != .normal { return .angry }
        let byCPU = cpuMood(cpu), byMemory = memoryMood(memory)
        let target = byCPU.rank >= byMemory.rank ? byCPU : byMemory
        guard target.rank < previous.rank else { return target }
        let heldByCPU = cpu >= cpuThreshold(of: previous) - hysteresis
        let heldByMemory = memoryThreshold(of: previous).map { memory >= $0 - hysteresis } ?? false
        return heldByCPU || heldByMemory ? previous : target
    }

    private static func cpuMood(_ cpu: Double) -> StrideMood {
        cpu >= cpuAngry ? .angry : cpu >= cpuSprint ? .sprint : cpu >= cpuRun ? .run : .sleep
    }

    private static func memoryMood(_ memory: Double) -> StrideMood {
        memory >= memoryAngry ? .angry : memory >= memorySprint ? .sprint : .sleep
    }

    private static func cpuThreshold(of mood: StrideMood) -> Double {
        switch mood {
        case .sleep: return 0
        case .run: return cpuRun
        case .sprint: return cpuSprint
        case .angry: return cpuAngry
        }
    }

    /// 内存不管睡觉和跑步，这两档撑不住。
    private static func memoryThreshold(of mood: StrideMood) -> Double? {
        switch mood {
        case .sleep, .run: return nil
        case .sprint: return memorySprint
        case .angry: return memoryAngry
        }
    }

    /// 每秒几帧：睡觉 2、生气 10；跑步和冲刺都是 8→10，随 CPU 在本档里的位置线性变快（内存顶上来的冲刺按 8）。
    /// 跑步原来从 4 起，一圈 8 帧要走 2 秒，看着像散步。封顶 10：Stride 实测菜单栏换图 10 fps 约 2% CPU。
    static func framesPerSecond(mood: StrideMood, cpu: Double) -> Double {
        func position(_ low: Double, _ high: Double) -> Double { min(max((cpu - low) / (high - low), 0), 1) }
        switch mood {
        case .sleep: return 2
        case .run: return 8 + 2 * position(cpuRun, cpuSprint)
        case .sprint: return 8 + 2 * position(cpuSprint, cpuAngry)
        case .angry: return 10
        }
    }

    /// 换状态等这一圈播完，姿势不半截跳变；进生气不等，出事了马上让人看到。
    static func switchesNow(to next: StrideMood, atLoopEnd: Bool) -> Bool {
        next == .angry || atLoopEnd
    }

    /// 恐龙旁边的读数：整数百分比。
    static func label(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    /// 蛋的颜色档。
    enum EggTone {
        case calm, warm, hot
    }

    /// 和内存推恐龙冲刺、生气是同一条线：蛋变橙时恐龙开始冲，变红裂开时生气。蛋不带滞回，显示的就是此刻的内存。
    static func eggTone(memory: Double) -> EggTone {
        memory >= memoryAngry ? .hot : memory >= memorySprint ? .warm : .calm
    }
}
