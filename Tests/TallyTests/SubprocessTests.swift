import XCTest
@testable import Tally

/// 真起子进程：截止时间、提前停、管道灌满、不理 SIGTERM、后台进程占着 stdout，这些只有真进程才测得出来。
final class SubprocessTests: XCTestCase {

    private let sh = URL(fileURLWithPath: "/bin/sh")

    private func timed(_ body: () throws -> Subprocess.Result) rethrows -> (Subprocess.Result, TimeInterval) {
        let start = Date()
        let result = try body()
        return (result, Date().timeIntervalSince(start))
    }

    func testDeadlineHoldsWhenChildSaysNothing() throws {
        // hook 安装卡死的那种：子进程不出声，原来的 availableData 循环会一直等下去
        let (result, elapsed) = try timed { try Subprocess.run(sh, ["-c", "sleep 5"], deadline: 0.5) }
        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.status)
        XCTAssertLessThan(elapsed, 2.5)
    }

    func testStopsAsSoonAsTheAnswerArrives() throws {
        let (result, elapsed) = try timed {
            try Subprocess.run(sh, ["-c", "echo ready; sleep 5"], deadline: 10) { String(decoding: $0, as: UTF8.self).contains("ready") }
        }
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ready\n")
        XCTAssertLessThan(elapsed, 2.5, "等到了就结束子进程，不陪它睡满")
    }

    func testStderrFloodDoesNotBlockTheChild() throws {
        // 200 KB 写进 stderr：只读 stdout 的话子进程会卡在写 stderr 上
        let (result, _) = try timed { try Subprocess.run(sh, ["-c", "head -c 200000 /dev/zero >&2; echo done"], deadline: 5) }
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "done\n")
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    func testChildIgnoringTerminateIsKilled() throws {
        let (result, elapsed) = try timed { try Subprocess.run(sh, ["-c", "trap '' TERM; sleep 5"], deadline: 0.3) }
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(elapsed, 3, "SIGTERM 不理就 SIGKILL")
    }

    func testBackgroundProcessHoldingStdoutDoesNotHoldUsUntilDeadline() throws {
        // 启动脚本起了个后台进程、继承了 stdout：shell 早退了，管道却一直不关
        let (result, elapsed) = try timed { try Subprocess.run(sh, ["-c", "sleep 5 & echo hi"], deadline: 10) }
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hi\n")
        XCTAssertFalse(result.timedOut)
        XCTAssertLessThan(elapsed, 3)
    }

    func testInputReachesTheChild() throws {
        let result = try Subprocess.run(URL(fileURLWithPath: "/bin/cat"), [], input: Data("hello\n".utf8), deadline: 5) {
            String(decoding: $0, as: UTF8.self).contains("hello")
        }
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello\n")
    }
}
