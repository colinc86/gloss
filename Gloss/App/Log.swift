import OSLog

/// Loggers for the app target. Filter with
/// `log stream --predicate 'subsystem == "com.cnc.Gloss"' --level debug`.
nonisolated enum Log {
    static let subsystem = "com.cnc.Gloss"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let explorer = Logger(subsystem: subsystem, category: "explorer")
    static let viewer = Logger(subsystem: subsystem, category: "viewer")
    static let notes = Logger(subsystem: subsystem, category: "notes")
    static let database = Logger(subsystem: subsystem, category: "db")
    static let packet = Logger(subsystem: subsystem, category: "packet")
    static let transport = Logger(subsystem: subsystem, category: "transport")
    static let watcher = Logger(subsystem: subsystem, category: "watcher")
}
