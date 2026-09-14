import Foundation

/// 从 Claude Code 的 transcript（JSONL）找会话标题。hook 和 app 共用同一份规则。
///
/// 三个来源，按可靠程度排：
/// 1. `/rename` 留下的边车 `<transcript 目录>/<session_id>/custom-title.json`
/// 2. 文件末尾 64 KB 里最后一条 `ai-title` 或 `custom-title` 记录
/// 3. 整个文件扫一遍（只有 app 会做，且每个会话只做一次）
public enum TranscriptTitle {

    public static let tailBytes = 64 * 1024

    /// 边车优先，其次文件尾。
    public static func read(from url: URL, sessionId: String?) -> String? {
        if let sessionId, let sidecar = sidecarTitle(transcript: url, sessionId: sessionId) {
            return sidecar
        }
        return readTail(from: url)
    }

    public static func sidecarTitle(transcript: URL, sessionId: String) -> String? {
        let file = transcript.deletingLastPathComponent()
            .appendingPathComponent(sessionId)
            .appendingPathComponent("custom-title.json")
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = (object["customTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
    }

    public static func readTail(from url: URL) -> String? {
        guard let tail = tail(of: url) else { return nil }
        return parse(tail.text, truncated: tail.truncated)
    }

    /// 文件尾 64 KB 里最后一条带模型名的记录：Claude 回复的 `message.model`（跳过它自己报错时写的 `<synthetic>`），
    /// Codex 的 `turn_context.payload.model`。Codex 一轮很长时尾巴里没有 `turn_context`，它得靠 hook 入参的 `model`。
    public static func latestModel(in url: URL) -> String? {
        guard let tail = tail(of: url) else { return nil }
        var lines = tail.text.split(separator: "\n", omittingEmptySubsequences: false)
        if tail.truncated, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() where line.contains("\"model\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let model = (object["message"] as? [String: Any])?["model"] as? String, !model.isEmpty, model != "<synthetic>" {
                return model
            }
            if object["type"] as? String == "turn_context",
               let model = (object["payload"] as? [String: Any])?["model"] as? String, !model.isEmpty {
                return model
            }
        }
        return nil
    }

    /// 回合是怎么结束的。打断和 API 报错都不发 Stop，只能看 transcript，规则见 docs/ai.md「打断与 API 报错」。
    public enum TurnEnd: Equatable {
        case interrupted
        /// 关联值是界面上那句报错，如「You've hit your session limit · resets 3pm」。
        case apiError(String?)
    }

    public static func turnEnd(in url: URL) -> TurnEnd? {
        guard let tail = tail(of: url) else { return nil }
        return parseTurnEnd(tail.text, truncated: tail.truncated)
    }

    /// 从后往前找第一条主链对话记录：子 agent 的（`isSidechain`）和 Claude Code 注入的提示（`isMeta`）不算，
    /// 回合结束后追加的快照、模式、system 记录也不算。它是打断标记或 API 报错才算结束；尾巴里没有对话记录按没结束算。
    public static func parseTurnEnd(_ text: String, truncated: Bool) -> TurnEnd? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if truncated, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() where line.contains("\"user\"") || line.contains("\"assistant\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true
            else { continue }
            let content = (object["message"] as? [String: Any])?["content"]
            let texts = (content as? String).map { [$0] }
                ?? (content as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                ?? []
            if type == "user" {
                return texts.contains { $0.hasPrefix("[Request interrupted by user") } ? .interrupted : nil
            }
            return object["isApiErrorMessage"] as? Bool == true ? .apiError(texts.first) : nil
        }
        return nil
    }

    /// 文件尾 `tailBytes` 字节；`truncated` 为真时第一行是被截断的半行。
    private static func tail(of url: URL) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let length = min(Int(size), tailBytes)
        guard length > 0 else { return nil }
        do {
            try handle.seek(toOffset: size - UInt64(length))
            guard let data = try handle.read(upToCount: length) else { return nil }
            return (String(decoding: data, as: UTF8.self), Int(size) > tailBytes)
        } catch {
            return nil
        }
    }

    /// 整个文件扫一遍。大 transcript 有几 MB，调用方要缓存结果。
    public static func readFull(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(String(decoding: data, as: UTF8.self), truncated: false)
    }

    public static func parse(_ text: String, truncated: Bool) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if truncated, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() where line.contains("\"ai-title\"") || line.contains("\"custom-title\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            let raw: String?
            switch type {
            case "ai-title": raw = object["aiTitle"] as? String
            case "custom-title": raw = object["customTitle"] as? String
            default: raw = nil
            }
            guard let title = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { continue }
            return title
        }
        return nil
    }
}
