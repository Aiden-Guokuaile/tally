import Foundation

/// 跑一个子进程，截止时间对每条路径都生效。
///
/// 不直接用 `readDataToEndOfFile` / `availableData` 读：两者在管道没数据时都一直阻塞，截止时间只能在两次读之间检查，
/// 子进程一声不吭就永远等下去（hook 安装的「上限 20 秒」就是这么失效的：上限 2 秒、子进程 6 秒不出声，照样等满 6 秒）。
/// 这里 stdout、stderr 各挂一个 readabilityHandler 同时收（stderr 灌满 64 KB 管道也堵不住子进程），
/// 调用方只在信号量上按截止时间等；到点先 SIGTERM，1 秒后还在就 SIGKILL——terminate 只是请求，子进程可以不理。
/// 只杀直接子进程：它自己起的孙进程要靠它转发 SIGTERM（codex 的 node 外壳会转发）；真碰上不转发还不退的，得改成单独进程组再整组杀。
enum Subprocess {

    struct Result {
        var stdout: Data
        var stderr: Data
        /// 到截止时间子进程还在跑。
        var timedOut: Bool
        /// 自己正常退出时的退出码；被信号结束或没等到退出为 nil。
        var status: Int32?
    }

    /// 同步跑完再返回，别在主线程上调用长的。
    /// - Parameters:
    ///   - input: 写进 stdin 的内容，写完 stdin 一直开着到结束（app-server 在 stdin 关掉时会退出）；nil 就不接管 stdin。
    ///   - until: 看 stdout 目前收到的全部内容，返回 true 就不再等、随即结束子进程；nil 表示等它自己退出。
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                    input: Data? = nil, deadline: TimeInterval, until: ((Data) -> Bool)? = nil) throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        if input != nil { process.standardInput = stdinPipe }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lock = NSLock()
        var out = Data()
        var err = Data()
        var outClosed = false
        var exited = false
        // 有新输出、stdout 关了、进程退了，都叫醒等待的一方
        let wake = DispatchSemaphore(value: 0)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil }
            lock.withLock {
                if chunk.isEmpty { outClosed = true } else { out.append(chunk) }
            }
            wake.signal()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                lock.withLock { err.append(chunk) }
            }
        }
        process.terminationHandler = { _ in
            lock.withLock { exited = true }
            wake.signal()
        }

        try process.run()
        if let input {
            // 子进程要是一起来就退了，往它 stdin 写会收到 SIGPIPE，默认动作是把 Tally 整个带走；
            // 关掉这个信号，用会抛错的 write，写不进去就当没写（它的输出和退出码会说明发生了什么）
            _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? stdinPipe.fileHandleForWriting.write(contentsOf: input)
        }

        var end = DispatchTime.now() + deadline
        var timedOut = false
        while true {
            let state = lock.withLock { (done: until?(out) ?? false, exited: exited, closed: outClosed) }
            if state.done || (state.exited && state.closed) { break }
            // 进程退了而 stdout 还没关：多半是它起的后台进程占着管道，输出其实已经齐了，别为它等满截止时间
            if state.exited { end = min(end, .now() + 0.5) }
            if wake.wait(timeout: end) == .timedOut {
                timedOut = !state.exited
                break
            }
        }

        func waitForExit(_ seconds: TimeInterval) -> Bool {
            let limit = DispatchTime.now() + seconds
            while !lock.withLock({ exited }) {
                if wake.wait(timeout: limit) == .timedOut { return lock.withLock { exited } }
            }
            return true
        }
        if process.isRunning {
            process.terminate()
            if !waitForExit(1) {
                kill(process.processIdentifier, SIGKILL)
                _ = waitForExit(1)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if input != nil { try? stdinPipe.fileHandleForWriting.close() }
        let (stdout, stderr, didExit) = lock.withLock { (out, err, exited) }
        // 没退出时读 terminationStatus 会抛 ObjC 异常，先看 didExit
        let status = didExit && process.terminationReason == .exit ? process.terminationStatus : nil
        return Result(stdout: stdout, stderr: stderr, timedOut: timedOut, status: status)
    }
}
