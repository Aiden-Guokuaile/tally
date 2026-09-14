import Foundation

/// HTTP/1.1 `Transfer-Encoding: chunked` 的增量解码器，抄自作者的另一个 app（Watchdog）。
///
/// mihomo 的 `/proxies`、`/configs` 都是 chunked，一次性发完就结束；
/// 靠 `feed` 逐段喂入，解出多少返回多少，流式接口也一样能用。
struct ChunkedDecoder {
    private var buf: [UInt8] = []
    private(set) var isFinished = false

    /// 喂入新收到的字节，返回本次能完整解出的 body 片段。
    mutating func feed(_ bytes: Data) -> [Data] {
        guard !isFinished else { return [] }
        buf.append(contentsOf: bytes)

        var out: [Data] = []
        var cursor = 0

        while true {
            guard let crlf = indexOfCRLF(from: cursor) else { break }

            // chunk-size 行可能带扩展参数，形如 "1a;name=value"
            let sizeField = String(decoding: buf[cursor..<crlf], as: UTF8.self)
                .split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeField.trimmingCharacters(in: .whitespaces), radix: 16) else { break }

            let dataStart = crlf + 2
            // 需要凑齐 size 字节 body 外加结尾的 CRLF 才算一个完整 chunk
            guard buf.count >= dataStart + size + 2 else { break }

            if size == 0 {
                isFinished = true
                cursor = buf.count
                break
            }

            out.append(Data(buf[dataStart..<(dataStart + size)]))
            cursor = dataStart + size + 2
        }

        if cursor > 0 { buf.removeFirst(cursor) }
        return out
    }

    private func indexOfCRLF(from start: Int) -> Int? {
        var i = start
        while i + 1 < buf.count {
            if buf[i] == 0x0D, buf[i + 1] == 0x0A { return i }
            i += 1
        }
        return nil
    }
}
