import XCTest
@testable import Tally

final class SystemSamplerTests: XCTestCase {

    func testCPUFractionFromTickDeltas() {
        // 两个核：忙 (100+50+50) + (0+0+0) = 200，闲 500 + 300 = 800 → 200 / 1000
        let previous: [UInt32] = [100, 50, 800, 50, 10, 10, 100, 0]
        let current: [UInt32] = [200, 100, 1300, 100, 10, 10, 400, 0]
        XCTAssertEqual(SystemSampler.cpuFraction(previous: previous, current: current)!, 0.2, accuracy: 0.0001)
        XCTAssertNil(SystemSampler.cpuFraction(previous: previous, current: previous), "没走过时间")
        XCTAssertNil(SystemSampler.cpuFraction(previous: [1, 2, 3], current: [1, 2, 3]), "不是 4 的倍数")
    }

    func testFirstRealSampleHasNoCPUButHasMemory() throws {
        var sampler = SystemSampler()
        let first = sampler.sample()
        XCTAssertNil(first.cpuFraction)
        XCTAssertEqual(first.memoryTotal, try Self.shellMemsize(), "和 `sysctl -n hw.memsize` 一致")
        XCTAssertNotNil(first.memoryUsed)
        XCTAssertNotNil(first.diskTotal)
        Thread.sleep(forTimeInterval: 0.05)
        let second = sampler.sample()
        let cpu = try XCTUnwrap(second.cpuFraction)
        XCTAssertTrue((0...1).contains(cpu))
    }

    /// 真跑一次命令，不用采样器自己的读法来验采样器。
    private static func shell(_ executable: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shellMemsize() throws -> UInt64 {
        try XCTUnwrap(UInt64(try shell("/usr/sbin/sysctl", "-n", "hw.memsize")))
    }

    func testSystemPagePairShowsUnitOnce() {
        XCTAssertEqual(SystemPage.pairText("21.3 GB", "48 GB"), "21.3 / 48 GB")
        XCTAssertEqual(SystemPage.pairText("0 B", "0 B"), "0 / 0 B")
        XCTAssertEqual(SystemPage.pairText("512 MB", "2 GB"), "512 MB / 2 GB", "单位不同就都写")
    }

    func testMemoryPressureLevelsAndTopProcesses() {
        XCTAssertEqual(MemoryPressure(level: 1), .normal)
        XCTAssertEqual(MemoryPressure(level: 2), .warn)
        XCTAssertEqual(MemoryPressure(level: 4), .critical)
        XCTAssertNil(MemoryPressure(level: 0))
        XCTAssertEqual(MemoryPressure.warn.label, "偏紧")
        let top = SystemSampler.topProcesses(limit: 3)
        XCTAssertEqual(top.count, 3)
        XCTAssertTrue(top[0].bytes >= top[1].bytes && top[1].bytes >= top[2].bytes, "按占用降序")
        XCTAssertTrue(top.allSatisfy { !$0.name.isEmpty && $0.bytes > 0 })
        XCTAssertEqual(SystemSampler.processName(ProcessInfo.processInfo.processIdentifier), "xctest")
    }

    func testTrashScanAndEmptyOnTemporaryDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tally-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        for name in ["a.txt", "b.txt", "c.txt", "folder/inner.bin", ".DS_Store"] {
            try Data(repeating: 0x41, count: 10_000).write(to: dir.appendingPathComponent(name))
        }
        let info = TrashInfo.scan(directory: dir)
        XCTAssertEqual(info.count, 4, "三个文件加一个子目录，隐藏文件不算")
        XCTAssertGreaterThanOrEqual(info.bytes, 40_000, "子目录里的也算进大小")
        let result = TrashInfo.empty(directory: dir)
        XCTAssertEqual(result.removed, 5, "隐藏文件也一起删")
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 0)
        XCTAssertEqual(TrashInfo.scan(directory: dir), TrashInfo(count: 0, bytes: 0))
        try? FileManager.default.removeItem(at: dir)
    }

    func testLevels() {
        var s = SystemSample()
        s.memoryTotal = 100
        s.memoryUsed = 90
        XCTAssertEqual(s.memoryLevel, .critical)
        s.memoryUsed = 75
        XCTAssertEqual(s.memoryLevel, .warn)
        s.memoryUsed = 74
        XCTAssertEqual(s.memoryLevel, .ok)

        s.cpuFraction = 0.9
        XCTAssertEqual(s.cpuLevel, .critical)
        s.cpuFraction = 0.7
        XCTAssertEqual(s.cpuLevel, .warn)
        s.cpuFraction = nil
        XCTAssertNil(s.cpuLevel)

        s.diskTotal = 1000
        s.diskAvailable = 99
        XCTAssertEqual(s.diskLevel, .critical)
        s.diskAvailable = 199
        XCTAssertEqual(s.diskLevel, .warn)
        s.diskAvailable = 200
        XCTAssertEqual(s.diskLevel, .ok)

        XCTAssertNil(s.batteryLevel, "没电池")
        s.battery = BatteryHealth(percent: 15, state: .charging, healthPercent: nil, cycleCount: nil)
        XCTAssertEqual(s.batteryLevel, .ok, "充电中一律绿")
        s.battery?.state = .full
        XCTAssertEqual(s.batteryLevel, .ok, "已充满也绿")
        s.battery?.state = .discharging
        XCTAssertEqual(s.batteryLevel, .warn)
        s.battery?.percent = 10
        XCTAssertEqual(s.batteryLevel, .critical)
        s.battery?.percent = 21
        XCTAssertEqual(s.batteryLevel, .ok)
    }

    func testBatteryStateHealthAndLevel() {
        XCTAssertEqual(BatteryHealth.state(isCharging: true, externalConnected: true, percent: 50), .charging)
        XCTAssertEqual(BatteryHealth.state(isCharging: false, externalConnected: true, percent: 95), .full)
        XCTAssertEqual(BatteryHealth.state(isCharging: false, externalConnected: true, percent: 90), .onPower, "插着电但没在充也没到 95：接电源，不是放电")
        XCTAssertEqual(BatteryHealth.state(isCharging: false, externalConnected: false, percent: 100), .discharging)
        XCTAssertEqual(BatteryHealth.health(rawMax: 5565, design: 6249), 89, "兜底比值；系统信息那个口径是平滑过的，本机显示 93%")
        XCTAssertEqual(BatteryHealth.level(93), .ok)
        XCTAssertEqual(BatteryHealth.level(70), .warn)
        XCTAssertEqual(BatteryHealth.level(50), .critical)
        XCTAssertNil(BatteryHealth.level(nil))
        // 真机：和「系统信息 → 电源」显示的最大容量必须一致；没电池的机器跳过
        if let reported = BatteryHealth.systemReported() {
            XCTAssertGreaterThan(reported, 0)
            XCTAssertLessThanOrEqual(reported, 100)
        }
        XCTAssertNil(BatteryHealth.health(rawMax: 5565, design: 0))
        XCTAssertNil(BatteryHealth.health(rawMax: nil, design: 6249))
        XCTAssertEqual(BatteryHealth(percent: 1, state: .full, healthPercent: 85, cycleCount: nil).healthLevel, .ok)
        XCTAssertEqual(BatteryHealth(percent: 1, state: .full, healthPercent: 79, cycleCount: nil).healthLevel, .warn)
        XCTAssertEqual(BatteryHealth(percent: 1, state: .full, healthPercent: 59, cycleCount: nil).healthLevel, .critical)
        XCTAssertEqual(BatteryHealth.State.full.label, "已充满")
    }

    func testHardwareTexts() throws {
        let now = Date()
        XCTAssertEqual(HardwareInfo.uptimeText(from: now.addingTimeInterval(-(37 * 3600 + 5 * 60)), now: now), "1 天 13 小时")
        XCTAssertEqual(HardwareInfo.uptimeText(from: now.addingTimeInterval(-(13 * 3600 + 5 * 60)), now: now), "13 小时 5 分钟")
        XCTAssertEqual(HardwareInfo.uptimeText(from: now.addingTimeInterval(-5 * 60), now: now), "5 分钟")
        var info = HardwareInfo(chip: "Apple M3 Max", performanceCores: 12, efficiencyCores: 4, memoryTotal: 0, osVersion: "", bootTime: now)
        XCTAssertEqual(info.coresText, "16（12 性能 + 4 能效）")
        info.efficiencyCores = nil
        info.performanceCores = 8
        XCTAssertEqual(info.coresText, "8", "Intel 没有能效核")
        XCTAssertEqual(HardwareInfo.versionText(OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)), "26.2")
        XCTAssertEqual(HardwareInfo.versionText(OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 1)), "26.2.1")

        let real = try XCTUnwrap(HardwareInfo.read())
        XCTAssertEqual(real.chip, try Self.shell("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"), "和 sysctl 命令一致")
        XCTAssertEqual(real.memoryTotal, try Self.shellMemsize())
        XCTAssertTrue(real.bootTime < now)
    }

    func testByteFormatTiersAndZeroStripping() {
        XCTAssertEqual(ByteFormat.string(0), "0 B")
        XCTAssertEqual(ByteFormat.string(512), "512 B")
        XCTAssertEqual(ByteFormat.string(12_595), "12.3 KB")
        XCTAssertEqual(ByteFormat.string(1_258_291), "1.2 MB")
        XCTAssertEqual(ByteFormat.string(22_871_155_507), "21.3 GB")
        XCTAssertEqual(ByteFormat.string(51_539_607_552), "48 GB")
        XCTAssertEqual(ByteFormat.string(2 * 1024 * 1024 * 1024), "2 GB")
        XCTAssertEqual(ByteFormat.rate(1_258_291), "1.2 MB/s")
        XCTAssertEqual(ByteFormat.rate(-5), "0 B/s")
    }
}
