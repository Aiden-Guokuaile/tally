import Foundation
import Network

enum MihomoError: Error, Equatable {
    /// socket 文件不存在：内核没在跑。
    case notRunning
    case badStatus(String)
    /// 连上了但对方一直不回：不设超时这条连接会永远挂着。
    case timeout
}

/// 只读的 GET 接口，方便测试塞假实现。
protocol MihomoRequesting {
    @discardableResult
    func get(_ path: String, onLine: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void) -> NWConnection?
}

/// 走 Unix domain socket 的极简 HTTP/1.1 GET 客户端，连接与解码抄自作者的另一个 app（Watchdog）。
///
/// 默认 socket 路径是 Watchdog 暴露其 mihomo 内核控制接口的位置；别的 mihomo 客户端走 TCP 9090 + secret，不接，
/// 它们的代理卡片只有系统代理那几行。socket 文件不存在时整段功能不出现，不影响别的。
///
/// 只服务 mihomo 的本地控制接口，所以没有 TLS、重定向、连接复用；一次请求一条连接。
/// body 按行交付：流式接口一行一条 JSON，`/configs`、`/proxies` 这种一整段不带换行的在关闭时作为尾巴交付。
/// 回调全在主线程。
final class MihomoClient: MihomoRequesting {

    static let defaultSocketPath = "/tmp/gauge/core.sock"

    let socketPath: String
    let timeout: TimeInterval

    init(socketPath: String = MihomoClient.defaultSocketPath, timeout: TimeInterval = 8) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    /// 不抛错：socket 文件不存在返回 nil 并同步调 `onClose(.notRunning)`；
    /// 连接被拒、中途断开、状态不是 2xx 走 `onClose(error)`，正常结束 `onClose(nil)`。
    @discardableResult
    func get(_ path: String, onLine: @escaping (Data) -> Void, onClose: @escaping (Error?) -> Void) -> NWConnection? {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            onClose(MihomoError.notRunning)
            return nil
        }
        let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)

        var headerParsed = false
        var isChunked = false
        var contentLength: Int?
        var bodyReceived = 0
        var head = Data()
        var decoder = ChunkedDecoder()
        var lines = LineSplitter()
        var closed = false

        func finish(_ error: Error?) {
            guard !closed else { return }
            closed = true
            conn.cancel()
            // 尾巴先于 onClose 交付，/configs 这种不带换行的 body 就靠这一次
            if let tail = lines.flush() { onLine(tail) }
            onClose(error)
        }

        func emitBody(_ data: Data) {
            if isChunked {
                for payload in decoder.feed(data) {
                    for line in lines.feed(payload) { onLine(line) }
                }
                if decoder.isFinished { finish(nil) }
            } else if !data.isEmpty {
                for line in lines.feed(data) { onLine(line) }
                bodyReceived += data.count
                if let contentLength, bodyReceived >= contentLength { finish(nil) }
            }
        }

        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { data, _, isComplete, error in
                if let error {
                    finish(error)
                    return
                }
                if let data, !data.isEmpty {
                    if headerParsed {
                        emitBody(data)
                    } else {
                        head.append(data)
                        if let sep = head.firstRange(of: Data("\r\n\r\n".utf8)) {
                            let rawHead = String(decoding: head[head.startIndex..<sep.lowerBound], as: UTF8.self)
                            let body = Data(head[sep.upperBound...])
                            headerParsed = true
                            head = Data()

                            let statusLine = rawHead.split(separator: "\r\n").first.map(String.init) ?? ""
                            guard let code = Self.statusCode(in: statusLine), (200..<300).contains(code) else {
                                finish(MihomoError.badStatus(statusLine.isEmpty ? "无响应状态行" : statusLine))
                                return
                            }
                            let lowerHead = rawHead.lowercased()
                            isChunked = lowerHead.contains("transfer-encoding: chunked")
                            if !isChunked {
                                contentLength = Self.contentLength(in: lowerHead)
                            }
                            if code == 204 || contentLength == 0 {
                                finish(nil)
                                return
                            }
                            emitBody(body)
                        }
                    }
                }
                if isComplete {
                    finish(nil)
                    return
                }
                receive()
            }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let req = "GET \(path) HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(req.utf8), completion: .contentProcessed { sendError in
                    if let sendError { finish(sendError) }
                })
                receive()
            case .failed(let error):
                finish(error)
            // socket 文件在但没人听时 NWConnection 停在 .waiting 自旋，直接判失败让上层按节奏重连
            case .waiting(let error):
                finish(error)
            case .cancelled:
                finish(nil)
            default:
                break
            }
        }

        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(MihomoError.timeout)
        }
        return conn
    }

    private static func statusCode(in statusLine: String) -> Int? {
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    private static func contentLength(in lowercasedHead: String) -> Int? {
        for line in lowercasedHead.split(separator: "\r\n") where line.hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

/// 把 body 字节流切成行：去掉行尾 `\n` 与 `\r`，空行不交付，没换行的尾巴由 `flush` 交付。
struct LineSplitter {
    private var pending = Data()

    mutating func feed(_ data: Data) -> [Data] {
        pending.append(data)
        var out: [Data] = []
        while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Self.strip(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
            if !line.isEmpty { out.append(line) }
        }
        return out
    }

    mutating func flush() -> Data? {
        let tail = Self.strip(pending[...])
        pending = Data()
        return tail.isEmpty ? nil : tail
    }

    private static func strip(_ slice: Data.SubSequence) -> Data {
        var line = Data(slice)
        while line.last == UInt8(ascii: "\r") { line.removeLast() }
        return line
    }
}
