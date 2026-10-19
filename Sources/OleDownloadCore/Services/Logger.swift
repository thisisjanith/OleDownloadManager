import Foundation
import os

/// Unified logging categories. Never log full URLs or headers: pass them through `Redactor` first.
public enum AppLog {
    public static let subsystem = "com.oledownloadmanager.app"
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let coordinator = Logger(subsystem: subsystem, category: "coordinator")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let filesystem = Logger(subsystem: subsystem, category: "filesystem")
    public static let browser = Logger(subsystem: subsystem, category: "browser")
}
