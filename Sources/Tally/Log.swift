import os

/// 统一日志出口。看日志：`log stream --predicate 'subsystem == "com.aiden.tally"' --level debug`
enum Log {
    private static let logger = Logger(subsystem: "com.aiden.tally", category: "app")

    static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
