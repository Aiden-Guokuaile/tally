import XCTest
@testable import Tally

private struct FakeTable: ProcessTable {
    let rows: [ProcessEntry]
    func entries() -> [ProcessEntry] { rows }
    func arguments(of pid: Int32) -> [String] { [] }
}

final class ProxyAppDetectorTests: XCTestCase {

    private func entry(_ pid: Int32, _ ppid: Int32) -> ProcessEntry {
        ProcessEntry(pid: pid, ppid: ppid, comm: "x", path: "/x", tdev: nil)
    }

    func testWalksUpToTheOwningApplication() {
        let table = FakeTable(rows: [entry(100, 1), entry(200, 100), entry(300, 200)])
        XCTAssertEqual(ProxyAppDetector.owningApplicationPid(of: 300, table: table, isApplication: { $0 == 100 }), 100, "内核 → 中间进程 → app")
        XCTAssertEqual(ProxyAppDetector.owningApplicationPid(of: 100, table: table, isApplication: { $0 == 100 }), 100, "本身就是 app")
        XCTAssertNil(ProxyAppDetector.owningApplicationPid(of: 300, table: table, isApplication: { _ in false }), "一路走到 launchd 都不是 app")
        XCTAssertNil(ProxyAppDetector.owningApplicationPid(of: 999, table: table, isApplication: { _ in false }), "表里没有")
    }

    func testLocalPortOnlyForLoopbackAndKnownList() {
        XCTAssertEqual(ProxyAppDetector.localPort(of: "127.0.0.1:7899"), 7899)
        XCTAssertEqual(ProxyAppDetector.localPort(of: "localhost:1080"), 1080)
        XCTAssertNil(ProxyAppDetector.localPort(of: "10.0.0.5:8080"), "指向别的主机不反查本地端口")
        XCTAssertNil(ProxyAppDetector.localPort(of: nil))
        XCTAssertNil(ProxyAppDetector.localPort(of: "nonsense"))
        XCTAssertEqual(ProxyAppDetector.knownRunning(among: ["com.apple.finder", "com.aiden.gauge"]), "com.aiden.gauge", "名单命中")
        XCTAssertNil(ProxyAppDetector.knownRunning(among: ["com.apple.finder"]))
    }

    func testListeningPidMatchesLsof() throws {
        let port = ProxyAppDetector.localPort(of: InterfaceSampler.systemProxy().http) ?? 7899
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let expected = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").first { $0.hasPrefix("p") }.flatMap { pid_t($0.dropFirst()) }
        XCTAssertEqual(ProxyAppDetector.listeningPid(port: port), expected, "和 lsof 命令一致（都没有时都是 nil）")
    }
}
