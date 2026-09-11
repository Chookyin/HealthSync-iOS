import Foundation
import os

/// 统一日志封装（os.Logger）。
public enum Logger {
    private static let subsystem = "com.example.HealthSync"
    private static let logger = os.Logger(subsystem: subsystem, category: "HealthSync")

    public static func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }

    public static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
