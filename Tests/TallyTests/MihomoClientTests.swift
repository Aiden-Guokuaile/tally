import XCTest
@testable import Tally

/// 用一个真的 Unix socket 服务端验客户端：头解析、Content-Length 与 chunked、按行交付、尾巴先于 onClose、非 2xx。
final class MihomoClientTests: XCTestCase {

    /// 一次性 HTTP 服务端：接一个连接，读完请求头就写固定响应，然后关连接。
    private final class OneShotServer {
        let path: String
        private let fd: Int32
        private(set) var request = ""

        init(response: String, delay: TimeInterval = 0) throws {
            path = NSTemporaryDirectory() + "tally-\(UUID().uuidString.prefix(8)).sock"
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            _ = path.withCString { cstr in
                withUnsafeMutablePointer(to: &addr.sun_path) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 104) { strlcpy($0, cstr, 104) }
                }
            }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, listen(fd, 1) == 0 else { throw NSError(domain: "bind", code: Int(errno)) }
            let listening = fd
            Thread {
                let client = accept(listening, nil, nil)
                guard client >= 0 else { return }
                // 超时那条用例里客户端早就走了，晚到的 write 会收到 SIGPIPE，默认动作是把整个测试进程带走
                // （几秒后发作，死在随便哪个后面的用例里）；关掉它，写失败就是写失败
                var noSigpipe: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                var buffer = [UInt8](repeating: 0, count: 4096)
                var head = Data()
                while head.range(of: Data("\r\n\r\n".utf8)) == nil {
                    let n = read(client, &buffer, buffer.count)
                    if n <= 0 { break }
                    head.append(contentsOf: buffer[0..<n])
                }
                self.request = String(decoding: head, as: UTF8.self)
                if delay > 0 { Thread.sleep(forTimeInterval: delay) }
                _ = response.withCString { write(client, $0, strlen($0)) }
                shutdown(client, SHUT_WR)
                close(client)
            }.start()
        }

        deinit {
            close(fd)
            unlink(path)
        }
    }

    private func run(_ response: String, path: String = "/x", delay: TimeInterval = 0, timeout: TimeInterval = 8) throws -> (lines: [String], events: [String], error: Error?, request: String) {
        let server = try OneShotServer(response: response, delay: delay)
        let client = MihomoClient(socketPath: server.path, timeout: timeout)
        var lines: [String] = []
        var events: [String] = []
        var closeError: Error?
        let closed = expectation(description: "closed")
        client.get(path, onLine: { data in
            XCTAssertTrue(Thread.isMainThread, "回调在主线程")
            lines.append(String(decoding: data, as: UTF8.self))
            events.append("line")
        }, onClose: { error in
            closeError = error
            events.append("close")
            closed.fulfill()
        })
        wait(for: [closed], timeout: 5)
        return (lines, events, closeError, server.request)
    }

    func testContentLengthBodyWithoutNewlineIsDeliveredBeforeClose() throws {
        let body = #"{"mode":"rule"}"#
        let result = try run("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nContent-Type: application/json\r\n\r\n\(body)", path: "/configs")
        XCTAssertEqual(result.lines, [body])
        XCTAssertEqual(result.events, ["line", "close"], "尾巴先于 onClose 交付")
        XCTAssertNil(result.error)
        XCTAssertTrue(result.request.hasPrefix("GET /configs HTTP/1.1\r\n"), result.request)
        XCTAssertTrue(result.request.contains("Connection: close\r\n"))
    }

    func testChunkedBodyIsSplitIntoLinesWithTail() throws {
        func chunk(_ s: String) -> String { String(s.utf8.count, radix: 16) + "\r\n" + s + "\r\n" }
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + chunk("{\"up\":1}\n{\"up\":2}\n") + chunk("{\"up\":3}") + "0\r\n\r\n"
        let result = try run(response, path: "/stream")
        XCTAssertEqual(result.lines, [#"{"up":1}"#, #"{"up":2}"#, #"{"up":3}"#])
        XCTAssertEqual(result.events, ["line", "line", "line", "close"])
        XCTAssertNil(result.error)
    }

    func testNon2xxIsAnErrorWithoutLines() throws {
        let result = try run("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
        XCTAssertEqual(result.lines, [])
        XCTAssertEqual(result.error as? MihomoError, .badStatus("HTTP/1.1 404 Not Found"))
    }

    func testPeerThatNeverAnswersTimesOut() throws {
        let started = Date()
        let result = try run("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok", delay: 3, timeout: 0.5)
        XCTAssertEqual(result.error as? MihomoError, .timeout)
        XCTAssertEqual(result.lines, [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "超时后不等对方")
    }

    func testMissingSocketReportsNotRunningSynchronously() {
        let client = MihomoClient(socketPath: NSTemporaryDirectory() + "tally-nope-\(UUID().uuidString).sock")
        var closeError: Error?
        let conn = client.get("/configs", onLine: { _ in XCTFail("不该有数据") }, onClose: { closeError = $0 })
        XCTAssertNil(conn)
        XCTAssertEqual(closeError as? MihomoError, .notRunning)
    }
}
