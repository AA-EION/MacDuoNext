import os

/// Engine diagnostics. Read with:
///
///     log show --last 5m --predicate 'subsystem == "com.macduonext.app"'
enum EngineLog {
    static let render = Logger(subsystem: "com.macduonext.app", category: "engine")
}
