import XCTest
@testable import Tally

/// 回归：解析器按块清自动释放池。没有池时峰值内存约是输入大小的两倍（每块 NSData 加每行的 JSON 对象图），
/// 记录数和去重键却一模一样，所以只能用内存上限来抓。
final class JSONLUsageParserMemoryTests: XCTestCase {

    func testAggregateFootprintStaysBounded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tally-parser-mem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 4 个文件共约 120 MB：无池版本涨 250 MB 以上，有池版本几十 MB。
        let now = Date()
        let files = try (0..<4).map { i -> URL in
            let url = dir.appendingPathComponent("s\(i).jsonl")
            try Self.writeCorpus(to: url, bytes: 30 * 1024 * 1024, now: now)
            return url
        }

        let baseline = Self.footprint()
        XCTAssertGreaterThan(baseline, 0, "phys_footprint 读出 0，测量失效")
        var peak = baseline
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var snapshot = UsageSnapshot()
        DispatchQueue.global().async {
            snapshot = JSONLUsageParser.aggregate(files: files, now: now)
            done.signal()
        }
        while done.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            peak = max(peak, Self.footprint())
        }
        peak = max(peak, Self.footprint())

        XCTAssertGreaterThan(snapshot.week.outputTokens, 0, "语料没有被解析到")
        let growthMB = Int((peak - baseline) / (1024 * 1024))
        XCTAssertLessThan(growthMB, 100, "aggregate 峰值比基线高 \(growthMB) MB，自动释放池没起作用")
    }

    /// 每行一条 Claude 格式记录，约 1.2 KB，dedupKey 逐行不同以免被去重跳过。
    private static func writeCorpus(to url: URL, bytes: Int, now: Date) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let ts = iso.string(from: now.addingTimeInterval(-60))
        let filler = String(repeating: "x", count: 1000)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var written = 0
        var n = 0
        var chunk = Data()
        while written < bytes {
            let line = "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"requestId\":\"r\(n)\",\"message\":{\"id\":\"m\(n)\",\"model\":\"claude-sonnet-4-5\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50,\"cache_read_input_tokens\":20,\"cache_creation_input_tokens\":10},\"content\":\"\(filler)\"}}\n"
            chunk.append(contentsOf: line.utf8)
            written += line.utf8.count
            n += 1
            if chunk.count > 4 * 1024 * 1024 {
                handle.write(chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        handle.write(chunk)
    }

    /// 进程的物理内存占用（`phys_footprint`），和 `footprint -p` 报的是同一个数。
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        // 量不到就得红，否则 0 − 0 < 100 会让断言空过。
        XCTAssertEqual(kr, KERN_SUCCESS, "task_info(TASK_VM_INFO) 失败，内存没量到")
        return info.phys_footprint
    }
}
