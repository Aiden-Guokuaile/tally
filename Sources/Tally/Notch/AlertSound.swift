import AVFoundation

/// 会话提示音：跑完放 Glass，等审批 / 等输入放 Ping。
/// 走 AVAudioPlayer 不走 NSSound：系统设置里关掉「播放用户界面音效」后 NSSound 不出声。
@MainActor
enum AlertSound {
    /// 播放期间得有人拿着 player，局部变量一出作用域声音就停了。
    private static var player: AVAudioPlayer?
    private static var lastPlayed: Date?
    /// 这么久之内连着来的只响第一声：几个会话前后脚跑完，不该叮叮叮一串。
    nonisolated static let quietWindow: TimeInterval = 2

    static func name(for state: SessionRecord.State) -> String {
        state == .done ? "Glass" : "Ping"
    }

    nonisolated static func shouldPlay(lastPlayed: Date?, now: Date) -> Bool {
        lastPlayed.map { now.timeIntervalSince($0) >= quietWindow } ?? true
    }

    static func play(for state: SessionRecord.State) {
        let now = Date()
        guard shouldPlay(lastPlayed: lastPlayed, now: now) else { return }
        lastPlayed = now
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name(for: state)).aiff")
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.play()
        } catch {
            Log.error("提示音放不出来: \(error.localizedDescription)")
        }
    }
}
