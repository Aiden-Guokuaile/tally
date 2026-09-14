import AppKit
import XCTest
@testable import Tally

/// 菜单栏小恐龙的状态判定与蛋（docs/monitors.md「菜单栏小恐龙」）。
final class StrideRuleTests: XCTestCase {

    private func mood(cpu: Double, memory: Double = 0.47, pressure: MemoryPressure? = .normal, from previous: StrideMood = .sleep) -> StrideMood {
        StrideRule.resolve(cpu: cpu, memory: memory, pressure: pressure, previous: previous)
    }

    func testCPUDrivesSleepRunSprint() {
        XCTAssertEqual(mood(cpu: 0.05), .sleep, "内存平时 47% 不影响睡觉")
        XCTAssertEqual(mood(cpu: 0.12), .run, "几个 agent 在跑时（本机 9%–20%）是跑步")
        XCTAssertEqual(mood(cpu: 0.35), .sprint)
        XCTAssertEqual(mood(cpu: 0.62), .angry, "编译这种重活就生气，不用等到 100%")
    }

    func testTightMemoryPushesUp() {
        XCTAssertEqual(mood(cpu: 0.02, memory: 0.69), .sleep, "内存不管跑步：平时水位几乎不动")
        XCTAssertEqual(mood(cpu: 0.02, memory: 0.71), .sprint, "内存到 70% 闲着也冲刺，和蛋变橙同一条线")
        XCTAssertEqual(mood(cpu: 0.02, memory: 0.86), .angry, "85% 生气，和蛋变红裂开同一条线")
        XCTAssertEqual(mood(cpu: 0.65, memory: 0.71), .angry, "两项取更忙的")
        XCTAssertEqual(mood(cpu: 0.12, memory: 0.71), .sprint)
    }

    func testMemoryPressureAlwaysAngry() {
        XCTAssertEqual(mood(cpu: 0.01, pressure: .warn), .angry, "内核说偏紧就生气，不管读数")
        XCTAssertEqual(mood(cpu: 0.01, pressure: .critical), .angry)
        XCTAssertEqual(mood(cpu: 0.01, pressure: nil), .sleep, "读不到压力按正常")
    }

    func testGoingDownNeedsHysteresis() {
        XCTAssertEqual(mood(cpu: 0.28, from: .sprint), .sprint, "刚跌破 30% 不降，免得来回闪")
        XCTAssertEqual(mood(cpu: 0.24, from: .sprint), .run)
        XCTAssertEqual(mood(cpu: 0.02, from: .sprint), .sleep, "一下跌到底就直接睡")
        XCTAssertEqual(mood(cpu: 0.57, from: .angry), .angry)
        XCTAssertEqual(mood(cpu: 0.35, from: .run), .sprint, "往上立刻升")
        XCTAssertEqual(mood(cpu: 0.02, memory: 0.66, from: .sprint), .sprint, "内存顶上来的冲刺同样多降 5 个点才退")
        XCTAssertEqual(mood(cpu: 0.02, memory: 0.64, from: .sprint), .sleep)
        XCTAssertEqual(mood(cpu: 0.02, memory: 0.82, from: .angry), .angry)
        XCTAssertEqual(mood(cpu: 0.02, memory: 0.79, from: .angry), .sprint, "退出生气后内存还在 70% 以上，落到冲刺")
    }

    func testFrameRates() {
        XCTAssertEqual(StrideRule.framesPerSecond(mood: .sleep, cpu: 0.02), 2)
        XCTAssertEqual(StrideRule.framesPerSecond(mood: .run, cpu: 0.10), 8, "跑步和冲刺一样快，从 8 起")
        XCTAssertEqual(StrideRule.framesPerSecond(mood: .run, cpu: 0.20), 9, accuracy: 0.001)
        XCTAssertEqual(StrideRule.framesPerSecond(mood: .sprint, cpu: 0.02), 8, "内存顶上来的冲刺按冲刺的最低帧率")
        XCTAssertEqual(StrideRule.framesPerSecond(mood: .sprint, cpu: 0.90), 10, "封顶 10")
        XCTAssertEqual(StrideRule.framesPerSecond(mood: .angry, cpu: 0.01), 10)
    }

    func testSwitchTimingAndLabels() {
        XCTAssertTrue(StrideRule.switchesNow(to: .angry, atLoopEnd: false), "进生气马上切")
        XCTAssertFalse(StrideRule.switchesNow(to: .run, atLoopEnd: false), "别的等这一圈播完")
        XCTAssertTrue(StrideRule.switchesNow(to: .sleep, atLoopEnd: true))
        XCTAssertEqual(StrideRule.label(0.374), "37%")
        XCTAssertEqual(StrideRule.label(1.2), "100%")
        XCTAssertEqual(StrideMood.angry.frameName(11), "angry-12")
        XCTAssertEqual(StrideMood.run.frameName(0), "run-01")
    }

    func testEggToneFollowsMemoryLines() {
        XCTAssertEqual(StrideRule.eggTone(memory: 0.69), .calm)
        XCTAssertEqual(StrideRule.eggTone(memory: 0.70), .warm)
        XCTAssertEqual(StrideRule.eggTone(memory: 0.85), .hot)
    }

    /// 蛋真的画出来了：下半截填到内存高度、颜色跟着档走，上半截空着；深色模式外面有一圈暗晕，浅色没有。
    func testEggFillsToMemoryLevel() throws {
        let blank = try XCTUnwrap(CGContext(data: nil, width: 68, height: 36, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let half = StrideEgg.compose(frame: blank, memory: 0.5, dark: false)
        XCTAssertEqual(half?.size, StrideEgg.size, "恐龙 34pt 加蛋，一共 47 × 18pt")
        let low = try rgba(half, x: 41.0, y: 12.6)
        XCTAssertTrue(low[0] < 60 && low[1] < 60 && low[2] < 60 && low[3] > 200, "一半内存：蛋的下半截填成黑色（浅色菜单栏） \(low)")
        let high = try rgba(half, x: 40.6, y: 6.6)
        XCTAssertLessThan(high[3], 30, "上半截空着 \(high)")
        let tight = try rgba(StrideEgg.compose(frame: blank, memory: 0.9, dark: false), x: 41.0, y: 12.6)
        XCTAssertTrue(tight[0] > 170 && tight[1] < 60 && tight[2] < 80 && tight[3] > 200, "85% 以上填成红色 \(tight)")
        let outsideLight = try rgba(half, x: 44.5, y: 10.3)
        XCTAssertLessThan(outsideLight[3], 10, "浅色模式不加晕 \(outsideLight)")
        let outsideDark = try rgba(StrideEgg.compose(frame: blank, memory: 0.5, dark: true), x: 44.5, y: 10.3)
        // 门槛按对比页校准：canvas shadowBlur 3、α 0.75 在 1pt 白线外 0.5pt 处是 35，CG 同参数同样是 35；蛋是弧边，这一点实测 31
        XCTAssertGreaterThan(outsideDark[3], 20, "深色模式蛋外面有一圈暗晕，壁纸染色的菜单栏上才分得开 \(outsideDark)")
    }

    /// 按 pt 坐标（原点左上）取 @2x 位图的 RGBA。
    private func rgba(_ image: NSImage?, x: CGFloat, y: CGFloat) throws -> [UInt8] {
        let cg = try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        var data = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return true
        }
        XCTAssertTrue(drawn)
        // 位图内存的第 0 行是图的最上面一行
        let index = (Int(y * 2) * cg.width + Int(x * 2)) * 4
        return Array(data[index..<index + 4])
    }

    /// 72 帧素材都在：少一张动画就会卡在上一帧。
    func testAllFramesArePresent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/stride")
        for appearance in ["dark", "light"] {
            for mood in StrideMood.allCases {
                for index in 0..<mood.frameCount {
                    let file = root.appendingPathComponent("\(appearance)/\(mood.frameName(index)).png")
                    XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
                }
            }
        }
    }
}
