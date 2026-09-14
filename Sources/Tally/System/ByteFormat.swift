import Foundation

/// 字节数的显示，网络页与系统页共用。1024 进制四档；KB 以上一位小数，小数是 0 就不带。
enum ByteFormat {
    private static let units = ["KB", "MB", "GB"]

    static func string(_ bytes: UInt64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        return "\(text) \(units[unit])"
    }

    /// 速率就是字节数后面加 /s。
    static func rate(_ bytesPerSecond: Int) -> String {
        string(UInt64(max(0, bytesPerSecond))) + "/s"
    }
}
