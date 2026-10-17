import Foundation
import os

/// Read with:
///
///     log show --last 5m --predicate 'subsystem == "com.macduonext.app"'
///
/// Notice level, not info: info level lives only in memory, and `log show`
/// reads the on-disk store.
enum Diagnostics {
    static let geometry = Logger(subsystem: "com.macduonext.app", category: "geometry")
    static let lid = Logger(subsystem: "com.macduonext.app", category: "lid")
    static let tracking = Logger(subsystem: "com.macduonext.app", category: "tracking")
}
